# On-device schema and sync protocol

The phone's SQLite database is the **source of truth**. The VM copy is a derived, resumable
projection of it. If the VM burns down, the phone can rebuild it; if the phone is lost, the VM
holds everything already synced. Nothing is ever deleted on the phone except by explicit retention
policy.

---

## Why one wide table instead of a table per stream

A table per stream looks tidy and is a trap. There are roughly 200 candidate streams, they arrive
at wildly different cadences, and the set will keep growing as iOS adds types. Per-stream tables
mean a migration every time a new HealthKit identifier appears, and every query becomes a union.

One narrow table keyed by a `stream` string absorbs new streams with zero schema change, and SQLite
indexes it fine at the volumes involved (a heavy day is low tens of thousands of rows).

---

## Tables

```sql
PRAGMA journal_mode = WAL;      -- concurrent reader while a background collector writes
PRAGMA synchronous = NORMAL;    -- WAL + NORMAL is durable enough and much faster
PRAGMA foreign_keys = ON;

-- ---------------------------------------------------------------- streams
-- Registry of every stream the app knows how to collect. Populated at launch
-- from the collector definitions, so the DB is self-describing and the
-- dashboard needs no hardcoded knowledge of what a stream means.
CREATE TABLE IF NOT EXISTS streams (
  stream        TEXT PRIMARY KEY,   -- 'health.stepCount', 'motion.activity', 'shortcuts.app.open'
  domain        TEXT NOT NULL,      -- 'health' | 'motion' | 'location' | 'device' | 'shortcuts' | ...
  kind          TEXT NOT NULL,      -- 'interval' | 'point' | 'state' | 'blob'
  unit          TEXT,               -- canonical unit; NULL for non-numeric
  description   TEXT,
  tier          INTEGER NOT NULL,   -- 0 free / 1 paid-account / 2 approval-gated
  first_seen_at TEXT,
  last_seen_at  TEXT,
  sample_count  INTEGER NOT NULL DEFAULT 0
);

-- ---------------------------------------------------------------- samples
-- Every datum, from every collector. Deliberately narrow.
CREATE TABLE IF NOT EXISTS samples (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  stream       TEXT    NOT NULL REFERENCES streams(stream),

  ts_start     TEXT    NOT NULL,    -- ISO8601 with offset. Instants set ts_end = ts_start.
  ts_end       TEXT    NOT NULL,
  tz           TEXT,                -- IANA zone AT THE TIME OF THE SAMPLE, not at query time.
                                    -- Without this, travel silently corrupts every
                                    -- hour-of-day analysis you will ever run.

  value_num    REAL,                -- numeric payload
  value_text   TEXT,                -- categorical payload ('walking', 'charging', 'REM')
  unit         TEXT,                -- unit as actually recorded; may differ from canonical

  source       TEXT,                -- 'iPhone' | 'Apple Watch' | 'AirPods' | third-party app name
  source_uuid  TEXT,                -- the ORIGIN system's stable ID (HealthKit UUID, PHAsset
                                    -- localIdentifier, EKEvent eventIdentifier). This is what
                                    -- makes re-ingestion idempotent.
  meta         TEXT,                -- JSON blob for anything stream-specific

  ingested_at  TEXT    NOT NULL,    -- when WE learned it. ts_start is when it HAPPENED.
                                    -- The gap between them measures backfill latency and is
                                    -- the only way to tell a live sample from a late arrival.
  synced_at    TEXT                 -- NULL = not yet pushed to the VM
);

-- Idempotent backfill. The collector re-queries overlapping windows on EVERY launch by
-- design (that is how a signing lapse self-heals), so the same sample will be offered
-- many times. This index makes the duplicate a no-op instead of a corruption.
CREATE UNIQUE INDEX IF NOT EXISTS ux_samples_origin
  ON samples(stream, source_uuid) WHERE source_uuid IS NOT NULL;

-- Fallback dedup for streams with no origin ID (device state, Shortcuts events):
-- a stream cannot have two different values for the same instant from the same source.
CREATE UNIQUE INDEX IF NOT EXISTS ux_samples_synthetic
  ON samples(stream, ts_start, source) WHERE source_uuid IS NULL;

CREATE INDEX IF NOT EXISTS ix_samples_stream_time ON samples(stream, ts_start);
CREATE INDEX IF NOT EXISTS ix_samples_time        ON samples(ts_start);
CREATE INDEX IF NOT EXISTS ix_samples_unsynced    ON samples(id) WHERE synced_at IS NULL;

-- ---------------------------------------------------------------- anchors
-- HealthKit HKAnchoredObjectQuery anchors and every other collector's
-- resume cursor. Losing this table costs a full re-scan, never data.
CREATE TABLE IF NOT EXISTS anchors (
  stream      TEXT PRIMARY KEY,
  anchor_blob BLOB,                 -- NSKeyedArchiver'd HKQueryAnchor
  cursor_ts   TEXT,                 -- for time-windowed collectors
  updated_at  TEXT NOT NULL
);

-- ---------------------------------------------------------------- runs
-- One row per collector execution. This is the app's own telemetry, and it is
-- what turns "is the background collector actually running?" from a guess into
-- a query. Non-negotiable for a system whose entire value is continuity.
CREATE TABLE IF NOT EXISTS runs (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  started_at   TEXT NOT NULL,
  ended_at     TEXT,
  trigger      TEXT NOT NULL,       -- 'foreground' | 'bgAppRefresh' | 'bgProcessing'
                                    -- | 'significantLocation' | 'visit' | 'region'
                                    -- | 'healthObserver' | 'appIntent' | 'launch'
  app_state    TEXT,                -- 'active' | 'background' | 'inactive'
  collected    INTEGER DEFAULT 0,
  errors       TEXT
);

-- ---------------------------------------------------------------- gaps
-- Explicitly recorded collection gaps. A hole in the data is itself a fact and
-- must be distinguishable from "nothing happened". Written when a run observes
-- that the previous run ended more than a threshold ago.
CREATE TABLE IF NOT EXISTS gaps (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  gap_start   TEXT NOT NULL,
  gap_end     TEXT NOT NULL,
  reason      TEXT,                 -- 'unknown' | 'profileExpired' | 'reboot'
                                    -- | 'backgroundRefreshDisabled' | 'permissionRevoked'
  backfilled  INTEGER NOT NULL DEFAULT 0
);
```

---

## The four rules the collectors must obey

1. **Write `tz` on every sample.** The timezone at the moment of the sample, not at query time.
   Zach travels; without this, every hour-of-day analysis is quietly wrong and you will not notice
   for months.
2. **`ingested_at` is never `ts_start`.** Their difference is the backfill latency, and it is the
   only way to distinguish a live sample from one that arrived four days late.
3. **Re-query overlapping windows on every launch.** Backfill is the self-healing mechanism for
   signing lapses and background-wake failures. The unique indexes make repetition free.
4. **Record the gap.** If the last run was long ago, write a `gaps` row before collecting. Absence
   of data must never be silently indistinguishable from absence of activity.

---

## Sync protocol

Phone-initiated, always. The VM cannot reach an idle iPhone — T-Mobile CGNAT plus iOS suspending
the WireGuard extension means unsolicited inbound never lands reliably. Every transfer is a push.

```
POST https://<host>/ingest
  Authorization: Bearer <device token>
  Content-Type: application/x-ndjson
  Content-Encoding: gzip

  {"id":41822,"stream":"health.stepCount","ts_start":"…","ts_end":"…","tz":"America/Chicago",
   "value_num":812,"unit":"count","source":"Apple Watch","source_uuid":"…","meta":{…}}
  … up to 5000 rows …

← 200 {"accepted":5000,"last_id":41822,"duplicates":37}
```

- Batches are ordered by `id` ascending; the server replies with the highest `id` it durably
  committed. The phone marks only up to that `id` as synced. A truncated upload therefore costs a
  retry, never a hole.
- The server applies the same uniqueness rule on `(stream, source_uuid)`, so a replayed batch is a
  no-op. Idempotency lives on both ends — the phone can always safely resend.
- Sync fires from OS wakeups only: significant-location-change, HealthKit background delivery, and
  `BGProcessingTask`, in that order of reliability. Never a timer, which iOS will not honour anyway.
- Transport is HTTPS over the existing Cloudflare tunnel, not the WireGuard tunnel, so sync works
  on any network without the VPN being up.

---

## Retention

Nothing is deleted on the phone by default. When storage pressure demands it, the eviction order is
by cost of loss, not by age: raw high-rate sensor blobs first (regenerable in aggregate),
then samples already synced and older than a year, then never anything that cannot be re-derived.
`CLVisit` and location history are **never** evicted before sync — they do not backfill, so a
deleted location row is gone permanently.
