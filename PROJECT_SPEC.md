# Project 172 — iOS Personal Telemetry

**Goal.** An iPhone app that collects Zach's personal telemetry to the fullest extent iOS allows,
stores it on-device as the source of truth, and syncs to the Oracle VM for long-horizon analysis
and a gated web dashboard.

**Hard constraint.** No Mac. Ever. Windows 11 only. Build on GitHub Actions macOS runners,
sign and install with Sideloadly on Windows.

**Hardware.** iPhone + Apple Watch + AirPods + iPad.

---

## The two-track approach

Half the questions here are research-shaped ("what streams does iOS expose") and half are
empirically-shaped ("will HealthKit sign with a free personal team", "do app-open automations
fire silently"). The second half have contested, version-stale answers online and definitive
answers on the actual phone in under an hour. So both tracks run at once:

| Track | What | Output |
|---|---|---|
| A — Survey | Exhaustive audit of the iOS 26 telemetry API surface | `docs/CAPABILITY-MATRIX.md` |
| B — Probe | A real app that measures what this phone + this Apple ID actually permit | `probe-report.json` |

**Nothing in the collector gets architected around a capability the probe has not confirmed.**
The failure mode this avoids: discovering in week two that the schema assumed a shared container
we cannot have.

---

## Phase 0 — the capability probe (`app/`)

One SwiftUI app, one target, no extensions (an extension needs App Groups, which may not be
provisionable on a free account — so extensions are deliberately deferred until the probe says
otherwise).

Eleven probes, each returning one `ProbeSection`:

| Probe | Answers |
|---|---|
| `EntitlementProbe` | Which entitlements survived signing; days until profile expiry; is the App Group container real |
| `HealthProbe` | Every HealthKit type, queried — what *this* hardware actually records, with real backfill depth |
| `MotionProbe` | Pedometer/activity history windows measured, not assumed; is `CMSensorRecorder` still alive |
| `LocationProbe` | Visit monitoring, SLC, geofence caps, iOS 17 `CLMonitor`, what relaunches a dead app |
| `StoresProbe` | Calendar, Contacts, Photos, Media — counts and depth, never content |
| `AmbientProbe` | Mic dB, SoundAnalysis classes, light proxies, SensorKit reachability |
| `NetworkProbe` | Radio tech, Wi-Fi entitlement, per-interface byte counters, BLE crowd count |
| `DeviceProbe` | Battery, thermal, storage, uptime, screen, accessibility fingerprint, lock-state |
| `FocusProbe` | Focus status, Focus Filters, and the Family Controls hard "no" |
| `IntentsProbe` | The zero-entitlement Shortcuts channel — plus a live App Intent to test it |
| `BackgroundProbe` | Background modes, BGTaskScheduler, and a launch ledger that measures real wakeups |

### The tier ladder

One compile, four IPAs, so the free-vs-$99 question is settled by the signing toolchain rather
than by argument:

| Artifact | Entitlements | Expectation |
|---|---|---|
| `Probe-unsigned.ipa` | none | control |
| `Probe-tier0.ipa` | none provisioned | must sign on a free Apple ID |
| `Probe-tier1.ipa` | HealthKit, HealthKit background delivery, App Groups | the $99 question |
| `Probe-tier2.ipa` | + wifi-info, Family Controls, SensorKit | expected to fail — that failure is the finding |

Everything gated only by an Info.plist usage string (CoreMotion, CoreLocation, EventKit,
Contacts, Photos, MediaPlayer, microphone, Bluetooth, Focus) needs **no entitlement at all** and
therefore works at tier 0. That is the backbone of the free build.

---

## Build pipeline (no Mac)

```
project.yml ──xcodegen──> Probe.xcodeproj ──xcodebuild (unsigned)──> Probe.app
                                                                       │
                                              ┌────────────────────────┤
                                    ad-hoc codesign --entitlements <tier>
                                              │
                                    Payload/ ──zip──> Probe-<tier>.ipa
                                              │
                                  GitHub artifact ──> Windows ──> Sideloadly ──> iPhone
```

macOS runners are free and unmetered on **public** repos and bill at a 10× multiplier on private
ones, so the repo is public. It contains code only — no telemetry, no report files, no secrets.

---

## Phase 1+ — the collector (design pending probe results)

Locked in already, because these do not depend on the probe:

- **On-device SQLite is the source of truth.** Sync is a derived, resumable projection of it.
- **Sync piggybacks on OS wakeups, never a timer.** Triggered by significant-location-change,
  HealthKit background delivery, and `BGTaskScheduler` — in that order of reliability. The VM
  cannot reach an idle iPhone (see `reference_ios_wireguard_inbound_limit.md`); every transfer is
  phone-initiated.
- **Aggressive backfill on every launch.** HealthKit, `CMPedometer`, and `CMMotionActivity` all
  backfill, so a signing lapse self-heals for those. `CLVisit` and location history do **not**
  backfill — a gap there is permanent. That asymmetry is what makes the $99 decision rational
  rather than a matter of taste.
- **Open-Meteo, not WeatherKit,** for location enrichment. Free, keyless, no entitlement, no
  paid-account gate.
- **Shortcuts personal automations are a first-class collector,** not a curiosity. An App Intent
  with `openAppWhenRun = false` accepts app-open/close, Apple Pay transactions, Focus changes,
  charger events, Wi-Fi joins and alarms — with zero entitlements, on a free account. This is the
  only viable route to per-app usage data, since `DeviceActivityReport` is sandboxed and cannot
  exfiltrate.

Deferred until the probe reports:

- Whether app extensions are possible at all (needs App Groups).
- Whether Screen Time is reachable (needs Family Controls approval).
- Whether HealthKit background delivery works at the current signing tier.

---

## Layout

```
app/          Xcode project (XcodeGen spec + Swift sources)
.github/      CI that builds the IPAs
docs/         capability matrix, runbook
server/       VM-side ingest + dashboard (phase 2)
research/     raw survey output
```
