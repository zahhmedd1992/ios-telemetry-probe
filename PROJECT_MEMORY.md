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

## Phase 0 shipped — 2026-07-24

Build is **green**. 16,756 lines of Swift across 14 files, ~400 capabilities probed, four IPAs in
`ipa/`. Waiting on Zach to sideload.

### Compile errors that cost a CI round-trip (all now fixed)

1. **`NWPath` is ambiguous** when both `Network` and `NetworkExtension` are imported —
   NetworkExtension exports a deprecated `NWPath` class of its own. Qualify as `Network.NWPath`,
   or every `.wifi` / `.cellular` member lookup fails to infer its base as a knock-on.
2. **`NSFastEnumerationIterator.next()` is mutating** — bind with `var`, not `let`.
3. **Type-checker timeout** on a four-stage `.map{}.sorted{}.map{}.joined()` chain over a
   `(String, Int)` tuple. Write it longhand; the fluent version does not compile.
4. **`CNContactStore.enumerator(for:)` is unavailable in Swift** and is NOT refined either —
   `__enumerator(for:)` does not exist. Reading Contacts change history requires an ObjC
   bridging header. Probe now reports reachability rather than risking `perform` against an
   `NSError**`, which would trap and destroy the whole report.
5. **`notify_register_check` / `notify_get_state` / `notify_cancel` are invisible to Swift** —
   public libSystem C API, but `notify.h` is in no module map iOS Swift can see. Resolved via
   `dlsym` against `RTLD_DEFAULT` (`UnsafeMutableRawPointer(bitPattern: -2)`) with
   `@convention(c)` typealiases. Optional throughout, so a vanished symbol degrades instead of
   failing the build.

Plus two the crosscheck pass caught before CI: `withTaskGroup` cannot be parameterised on an
unconstrained `T` (`ChildTaskResult: Sendable`), and `UIDevice.current` is main-actor isolated so
it cannot be read from a nonisolated synchronous context.

### The trap that would have cost an install cycle

A missing **or empty** `NS*UsageDescription` does not throw — **iOS terminates the process**. The
app just closes: no report, no error, no clue. Every "never traps" guarantee in the probe files is
void without the plist key. And discovering it costs one of only 10 App IDs per 7 days.

Now guarded permanently in CI: a step parses the **built** `Info.plist` (not `project.yml`, which
is one indirection away from what ships) and fails the build on any missing or blank key.
Currently 20/20.

### Also caught

- An agent cloned a prior-art repo (Overland) **into the Swift sources directory**. `.gitignore`
  now excludes `app/Probe/Probes/*/`.
- `git push` plus a manual `gh workflow run` cancel each other via the concurrency group. Push
  alone is enough.

## Track A complete — `docs/CAPABILITY-MATRIX.md` (1,063 lines, 434 capabilities, 11 domains)

**Correction to the earlier read on HealthKit.** Apple's own
[supported-capabilities-ios](https://developer.apple.com/help/account/reference/supported-capabilities-ios/)
table has a third column for the free Personal Team, and three researchers independently parsed the
**raw HTML** (the checkmarks render as `<figure class="icon icon-checksolid">` with no text, so
page-summarizers hallucinate them). The free column has exactly nine entries:

> App groups · Background modes · Data protection · **HealthKit** · HomeKit · Inter-App Audio ·
> Keychain sharing · Maps · Wireless Accessory Configuration

So HealthKit and App Groups are both listed as free. AltSign's six-entitlement allowlist — the
evidence that pointed the other way — is a property of **AltStore's implementation**, not of Apple's
membership tier. Sideloadly uses a different (zsign-lineage) signer, and our pipeline is different
again: hand-authored entitlements, unsigned CI build, re-signed on Windows, never touching Xcode's
Signing & Capabilities UI, which is where most reported behaviour comes from.

Net: HealthKit-on-free went from "probably needs $99" to "Apple says yes, verify it." The tier
ladder settles it either way.

**`healthkit.background-delivery` is a separate, second test.** It is not a row in Apple's table and
not configurable in the App ID portal UI — Xcode writes it silently when you tick HealthKit, and our
pipeline never runs Xcode. It fails at **runtime**, not build time, with
`HKError.errorAuthorizationDenied`. HealthProbe tests exactly this.

**The verdict:** build Tier 0 free; pay the $99 for the **1-year provisioning profile**, not for any
entitlement — because the 7-day expiry fails silently and silence is indistinguishable from "nothing
happened."

Section 10 lists 15+ testable assertions for the device probe. Blocking tests #1–3 (HealthKit signs /
background delivery signs / App Groups signs) are covered by the tier ladder plus EntitlementProbe's
real App-Group write test and HealthProbe's background-delivery attempt.

## Windows sideload stack — installed 2026-07-24

| Component | Version | State |
|---|---|---|
| iTunes (web installer, apple.com) | 12.13.10.3 | installed |
| Apple Mobile Device Support | 19.4.0.10 | **service Running** |
| Apple USB driver `appleusb.inf` | — | registered as `oem199.inf` (came from the Store *Apple Devices* app) |
| Sideloadly | v0.60 | `%LOCALAPPDATA%\Sideloadly\sideloadly.exe`, Start-menu entry |

### Trap: the iTunes bundle silently skips Apple Mobile Device Support

Running `iTunes64Setup.exe /passive /norestart` returned **exit code 0 in 34 seconds** and registered
iTunes 12.13.10.3 — but installed **only `iTunes64.msi`**. No AMDS, no service, no
`Common Files\Apple\Mobile Device Support`. `SetupAdmin.exe` appears to skip the device-support
component when the Microsoft Store **Apple Devices** app is present.

Sideloadly needs AMDS (the Windows usbmuxd equivalent). Without it the phone is invisible, and the
usual advice — rip out the Store apps and reinstall — would have killed Zach's iCloud photo sync.

**The non-destructive fix:**

```powershell
7z x iTunes64Setup.exe -o<dir>          # yields AppleMobileDeviceSupport64.msi (38 MB)
msiexec /i AppleMobileDeviceSupport64.msi /qn /norestart
```

The bundle contains exactly three files: `iTunes64.msi`, `AppleMobileDeviceSupport64.msi`,
`SetupAdmin.exe`. Installing the AMDS MSI directly closes the gap with zero collateral.

Two smaller ones:
- **Sideloadly is NSIS, not Inno Setup.** `/VERYSILENT` is ignored and the GUI sits there forever —
  it hung 10 minutes before this was spotted. The correct switch is `/S`, and it needs **no
  elevation** (installs per-user to `%LOCALAPPDATA%`).
- **IExpress `/T:<dir> /C` extraction hangs without `/Q`.** 7-Zip handles the bundle directly and is
  the better tool.

## Open

- 11 probe files being written; 5 done.
- Track A survey (11 domain researchers) still running.
- Unknown until the probe runs: App Group grant, HealthKit signing at free tier, HealthKit
  background delivery, real CoreMotion backfill windows, whether `CMSensorRecorder` still works.
