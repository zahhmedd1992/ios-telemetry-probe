# Project 172 — iOS Personal Telemetry · Running Log

## Status — 2026-07-24

Phase 0 (capability probe) in flight. Nothing shipped to the phone yet.

- Repo: `github.com/zahhmedd1992/ios-telemetry-probe` — **public on purpose** (macOS runners
  are free/unmetered on public repos, 10× billed on private). Code only, no telemetry.
- CI run #1: pipeline validated. XcodeGen spec is valid, project generates, and every
  hand-written file compiled. Only errors were the not-yet-written probe files.

## Verified facts (do not re-derive)

| Fact | Verified how | Date |
|---|---|---|
| GH Actions `macos-latest` = macOS 26.4, **Xcode 26.5**, **iOS 26.5 SDK** | CI log | 07.24 |
| XcodeGen `project.yml` with `info.properties` + `sdk:` deps + `weak: true` generates cleanly on Xcode 26.5 | CI log | 07.24 |
| Shortcuts automation **"Notify When Run" CAN be switched off** on iOS 26 (appears under "Run Immediately") | Zach, on device | 07.24 |
| iOS 26 automation run modes = Run Immediately / Run After Confirmation / Don't Run | Zach, on device | 07.24 |
| One App automation can target **multiple apps**, but exposes **no variable identifying which app fired** → per-app identity requires one automation per app | Apple Support + Sweet Setup | 07.24 |
| `.gitattributes` with `eol=lf` is mandatory — CRLF from Windows injects `\r` into CI `run:` blocks | preempted | 07.24 |

## Traps

1. **CRLF kills CI silently.** Committing from Windows without `.gitattributes` puts `\r` at the end
   of every line in a workflow `run:` block. Bash reports "command not found" for commands that are
   plainly correct. Fixed at commit 2.
2. **Entitlements files inside the `sources:` directory get bundled as app resources.** Moved to
   `app/entitlements/` and referenced only at ad-hoc-signing time.
3. **Unsigned builds do not embed entitlements.** `CODE_SIGNING_ALLOWED=NO` skips the entitlements
   file entirely, so a re-signing tool has nothing to read. The fix is a post-build
   `codesign --force --sign - --entitlements <file> --generate-entitlement-der`, which is also what
   makes the one-compile/four-tier ladder possible.
4. **HealthKit read authorization is opaque by design.** `authorizationStatus(for:)` reports SHARE
   status only. Whether data actually comes back is the only proof of read access — so the probe
   must query, never just ask.

## Decisions

- **Probe before collector.** Do not architect around any entitlement the probe has not confirmed.
  Specifically: App Groups is load-bearing (without it, no app extension can feed the collector),
  and its status is unknown until tier1 signs or fails.
- **Tier ladder over argument.** One compile → four IPAs (unsigned / tier0 / tier1 / tier2). The
  tier that fails to sign is the free-account ceiling, measured.
- **Shortcuts automations are a first-class collector**, now that the notification banner is
  confirmed off-able. Zero entitlements, works free, and it is the only route to per-app usage
  since `DeviceActivityReport` is sandboxed and cannot exfiltrate.
- **Open-Meteo over WeatherKit** — free, keyless, no entitlement, no paid-account gate.
- **Sync is phone-initiated, piggybacked on OS wakeups, never a timer.** The VM cannot reach an
  idle iPhone (see `reference_ios_wireguard_inbound_limit.md`).

## Open

- 11 probe files being written; 5 done.
- Track A survey (11 domain researchers) still running.
- Unknown until the probe runs: App Group grant, HealthKit signing at free tier, HealthKit
  background delivery, real CoreMotion backfill windows, whether `CMSensorRecorder` still works.
