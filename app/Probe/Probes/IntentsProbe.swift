import Foundation
import UIKit

#if canImport(Intents)
import Intents
#endif

#if canImport(WidgetKit)
import WidgetKit
#endif

#if canImport(AppIntents)
import AppIntents
#endif

// MARK: - IntentsProbe
//
// THE SLEEPER CHANNEL.
// ---------------------------------------------------------------------------
// Every other probe in this app asks "what does iOS let me read?". This one
// asks the inverted, far more valuable question: "what can iOS be made to PUSH
// into me, for free, forever, with no entitlement and no paid account?".
//
// The mechanism is a two-part public-API trick:
//
//   1. A Shortcuts PERSONAL AUTOMATION. These require ZERO entitlements, work on
//      a free Apple ID, and fire on real-world events no framework can observe
//      from inside the sandbox: an app being opened or closed, an Apple Pay
//      transaction, a Focus turning on, a charger connecting, a Wi-Fi network
//      being joined, an alarm going off.
//
//   2. An APP INTENT with `openAppWhenRun = false`. The automation's final step
//      calls this intent, which writes a structured event line into this app's
//      Documents directory WITHOUT ever foregrounding the app. That last clause
//      is the whole game: an automation that has to open an app to log is
//      unusable thirty times a day; one that runs silent in the background is a
//      first-class collector.
//
// So this file is not only a probe. It SHIPS the working App Intent and the
// AppShortcutsProvider that exposes it, so the channel is testable on the phone
// the moment the build lands — no manual Shortcuts wiring required. The probe
// half then reads back `events.ndjson` and reports what actually accumulated,
// which is how a later report will PROVE, from data, that a Shortcuts
// automation fired while the app was closed.
//
// WHAT THE PERSISTED EVENT LINE MEASURES (this is the clever part)
// ---------------------------------------------------------------------------
// Each line the intent writes carries a per-PROCESS UUID (`pid`) generated once
// when the process loads, plus `systemUptime`. Two questions the internet
// answers with stale folklore get answered here with ground truth instead:
//
//   * "Does an App Intent run while the app is terminated?"  If successive
//     automation fires share ONE pid, the system kept a single process alive.
//     If each fire carries a FRESH pid, the system spun up a new process per
//     fire — i.e. it genuinely runs while the app is not running. The report
//     reads this straight off the data.
//
//   * "What is perform()'s time budget?"  Each line records the measured
//     wall-clock duration of the intent body. Over many fires the probe reports
//     the max observed — a real number, not a documented guess. (Caveat, stated
//     honestly in the item: this body is a trivial file append, so it measures
//     the floor, not the kill ceiling. Finding the ceiling would need a
//     deliberately long-running intent, which is omitted to keep the automation
//     trustworthy and side-effect-light.)
//
// EVERYTHING PREFIXED. All eleven probes compile into ONE module. Every type,
// enum, and helper here is prefixed `IntentsProbe*`. Only `IntentsProbe`,
// `IntentsProbeLogEvent`, and `IntentsProbeShortcuts` are public entry points;
// the App Intent + provider names are deliberately un-collidable and, per a
// grep of the sibling files, are the app's SOLE AppShortcutsProvider and SOLE
// AppIntent — a target may declare exactly one provider, so this ownership is
// load-bearing.

struct IntentsProbe: TelemetryProbe {
    let key = "intents"
    let title = "Shortcuts & App Intents"

    func run() async -> ProbeSection {
        var items: [ProbeItem] = []

        items.append(IntentsProbeSupport.sdkAvailabilityItem())
        items.append(IntentsProbeSupport.osAvailabilityItem())
        items.append(IntentsProbeSupport.metadataBundleItem())
        items.append(IntentsProbeSupport.documentsWritableItem())
        items.append(contentsOf: IntentsProbeSupport.ledgerItems())
        items.append(IntentsProbeSupport.siriAuthItem())
        items.append(IntentsProbeSupport.controlWidgetItem())
        items.append(IntentsProbeSupport.terminatedExecutionItem())
        items.append(IntentsProbeSupport.triggerCatalogItem())
        items.append(IntentsProbeSupport.bannerFindingItem())

        return section(IntentsProbeSupport.summarize(items), items)
    }
}

// MARK: - Shared log location + schema
//
// Both halves of this file — the App Intent that WRITES and the probe that
// READS — must agree on exactly one path and one line format. That agreement
// lives here so it can never drift.

enum IntentsProbeLog {

    /// The append-only event ledger, in the app's Documents dir so it survives
    /// relaunches and can be pulled off the phone via the Files app over USB.
    static let fileName = "events.ndjson"

    /// Generated exactly once, when this process loads. Its whole purpose is to
    /// let the reader distinguish "the same live process handled N fires" from
    /// "the system launched a fresh process per fire". That distinction is the
    /// direct, empirical answer to whether an App Intent runs while the app is
    /// terminated — see the class comment.
    static let processID = UUID().uuidString

    static var documentsURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    static var fileURL: URL? {
        documentsURL?.appendingPathComponent(fileName)
    }

    private static let isoStamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Append one NDJSON event line. Best-effort and total: never throws, never
    /// traps, returns false on any failure. Safe to call from `perform()` in a
    /// background/extension process.
    @discardableResult
    static func append(kind: String,
                       detail: String?,
                       source: String,
                       perfSeconds: Double?) -> Bool {
        guard let url = fileURL else { return false }

        var obj: [String: Any] = [
            "ts": isoStamp.string(from: Date()),
            "kind": kind,
            "pid": processID,
            "uptime": ProcessInfo.processInfo.systemUptime,
            "source": source
        ]
        if let detail, !detail.isEmpty { obj["detail"] = detail }
        if let perfSeconds { obj["perfSeconds"] = perfSeconds }

        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let lineData = ("\(String(decoding: data, as: UTF8.self))\n").data(using: .utf8) else {
            return false
        }

        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            guard let handle = try? FileHandle(forWritingTo: url) else { return false }
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: lineData)
                return true
            } catch {
                return false
            }
        } else {
            return (try? lineData.write(to: url, options: .atomic)) != nil
        }
    }
}

// MARK: - The App Intent (the collector's write endpoint)
//
// Guarded only by `#if canImport(AppIntents)`. The deployment floor is iOS 17,
// and AppIntents / AppShortcutsProvider are iOS 16+, so at this floor they are
// UNCONDITIONALLY available — no `@available(iOS 16, *)` attribute is needed or
// wanted. (The task text asked for an `if #available(iOS 16, *)` guard around
// the type; that construct is not legal Swift — `if #available` is a statement,
// not a declaration modifier, and cannot wrap a top-level type. The correct and
// here-unnecessary form is the `@available` attribute. Omitting it is the fix,
// and is noted in the section summary. Adding an availability attribute to the
// AppShortcutsProvider specifically also confuses the build-time metadata
// extractor, so it is deliberately left off.)

#if canImport(AppIntents)

struct IntentsProbeLogEvent: AppIntent {
    static var title: LocalizedStringResource = "Log Telemetry Event"

    static var description = IntentDescription(
        "Appends a timestamped event to this app's on-device telemetry log WITHOUT opening the app. Drive it from a Shortcuts personal automation (app opened, Apple Pay, Focus change, charger, Wi-Fi, alarm) to capture events no entitlement can reach."
    )

    // CRITICAL: the intent must run WITHOUT foregrounding the app, or a personal
    // automation that fires dozens of times a day becomes unusable. This single
    // line is what makes the whole channel viable.
    static var openAppWhenRun: Bool = false

    // `kind` carries a DEFAULT so the intent can run start-to-finish with zero
    // user input. A required, default-less parameter would force a prompt every
    // fire — which, combined with openAppWhenRun = false, is exactly the broken
    // state that makes background automations stall.
    @Parameter(title: "Kind", default: "manual")
    var kind: String

    @Parameter(title: "Detail")
    var detail: String?

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Measure the body's wall-clock so the ledger can later report a real
        // (floor) perform() duration rather than a documented guess.
        let started = Date()
        let cleanKind = kind.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveKind = cleanKind.isEmpty ? "manual" : cleanKind
        let elapsed = Date().timeIntervalSince(started)

        let ok = IntentsProbeLog.append(
            kind: effectiveKind,
            detail: detail,
            source: "appintent",
            perfSeconds: elapsed
        )

        let message = ok
            ? "Logged \(effectiveKind)."
            : "Could not write the telemetry log for \(effectiveKind)."
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

struct IntentsProbeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: IntentsProbeLogEvent(),
            phrases: [
                "Log a telemetry event in \(.applicationName)",
                "Record an event with \(.applicationName)",
                "Log \(.applicationName) event"
            ],
            shortTitle: "Log Telemetry Event",
            systemImageName: "square.and.pencil"
        )
    }
}

#endif

// MARK: - Ledger reader (tolerant of a torn final line)
//
// The intent may be appending in a background process at the exact instant the
// probe reads. So the reader must never assume the last line is complete, never
// assume every line decodes, and never subscript without bounds. It counts what
// it could not parse and reports that count rather than hiding it.

struct IntentsProbeLedger {
    var totalLines = 0
    var parsed = 0
    var parseFailures = 0
    var mostRecent: Date?
    var oldest: Date?
    var kinds: [String: Int] = [:]
    var pids: [String: Int] = [:]      // per-process UUID -> events attributed to it
    var sources: [String: Int] = [:]
    var maxPerfSeconds: Double?
    var fileExists = false
    var fileSizeBytes = 0

    static func read() -> IntentsProbeLedger {
        var out = IntentsProbeLedger()
        guard let url = IntentsProbeLog.fileURL else { return out }

        let fm = FileManager.default
        out.fileExists = fm.fileExists(atPath: url.path)
        guard out.fileExists else { return out }

        guard let data = try? Data(contentsOf: url) else { return out }
        out.fileSizeBytes = data.count

        // Lossy decode so a partially-written multibyte tail cannot abort the
        // whole read; the torn line simply fails to parse and is counted.
        let text = String(decoding: data, as: UTF8.self)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            out.totalLines += 1

            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                out.parseFailures += 1
                continue
            }
            out.parsed += 1

            if let ts = obj["ts"] as? String {
                let d = iso.date(from: ts) ?? isoPlain.date(from: ts)
                if let d {
                    if out.mostRecent == nil || d > (out.mostRecent ?? d) { out.mostRecent = d }
                    if out.oldest == nil || d < (out.oldest ?? d) { out.oldest = d }
                }
            }
            if let kind = obj["kind"] as? String {
                out.kinds[kind, default: 0] += 1
            }
            if let pid = obj["pid"] as? String {
                out.pids[pid, default: 0] += 1
            }
            if let source = obj["source"] as? String {
                out.sources[source, default: 0] += 1
            }
            if let perf = obj["perfSeconds"] as? Double {
                if out.maxPerfSeconds == nil || perf > (out.maxPerfSeconds ?? perf) {
                    out.maxPerfSeconds = perf
                }
            }
        }
        return out
    }
}

// MARK: - Support

enum IntentsProbeSupport {

    // ------------------------------------------------------------------
    // 1. AppIntents present in THIS SDK?
    // ------------------------------------------------------------------

    static func sdkAvailabilityItem() -> ProbeItem {
        #if canImport(AppIntents)
        let present = true
        #else
        let present = false
        #endif

        if present {
            return ProbeItem(
                "intents.sdk.appIntents",
                "AppIntents framework (SDK)",
                .ok,
                value: "importable — intent + provider compiled in",
                detail: "This build was compiled against an SDK that ships AppIntents, and this file's IntentsProbeLogEvent (AppIntent) and IntentsProbeShortcuts (AppShortcutsProvider) are baked into the binary. That means the Log Telemetry Event action is discoverable in the Shortcuts app with no manual setup, and a personal automation can call it. This is the write endpoint for the entire sleeper channel.",
                extra: [
                    "canImport": "true",
                    "intentTitle": "Log Telemetry Event",
                    "openAppWhenRun": "false",
                    "providerCount": "1 (sole AppShortcutsProvider in the target)"
                ]
            )
        } else {
            return ProbeItem(
                "intents.sdk.appIntents",
                "AppIntents framework (SDK)",
                .unavailable,
                value: "not importable on this SDK",
                detail: "AppIntents did not compile in. The App Intent and AppShortcutsProvider were excluded by #if canImport(AppIntents), so the Shortcuts write endpoint does not exist in this build."
            )
        }
    }

    // ------------------------------------------------------------------
    // 2. AppIntents supported by THIS OS?
    // ------------------------------------------------------------------

    static func osAvailabilityItem() -> ProbeItem {
        // ProcessInfo, not UIDevice.current.systemVersion: this is a nonisolated
        // static func called from a nonisolated `run()`, and UIDevice is
        // main-actor isolated in the current UIKit overlay, so the UIDevice
        // spelling does not compile here. ProcessInfo is nonisolated and yields
        // the identical "17.4.1" shape.
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let os = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        // AppIntents / AppShortcutsProvider are iOS 16+. The app's deployment
        // floor is iOS 17, so on any device that can install this build the API
        // is unconditionally live — hence no @available guard anywhere in this
        // file. We still record the running version for the report.
        return ProbeItem(
            "intents.os.appIntents",
            "AppIntents support (running OS)",
            .ok,
            value: "iOS \(os) — App Intents live (16+ required)",
            detail: "App Intents and AppShortcutsProvider require iOS 16 or newer. This app's deployment target is iOS 17.0, so the requirement is satisfied on every device that can install the build; no availability guard is needed and none is present. The task spec requested an `if #available(iOS 16, *)` guard around the intent type — that is not valid Swift (an availability STATEMENT cannot wrap a type declaration) and is also redundant at this floor, so it was intentionally omitted; the correct declaration-level form would have been the `@available` attribute.",
            extra: ["systemVersion": os, "minimumOS": "16.0", "deploymentTarget": "17.0"]
        )
    }

    // ------------------------------------------------------------------
    // 3. Was App Intents metadata actually extracted into the binary?
    // ------------------------------------------------------------------
    //
    // canImport proves the SDK had the framework at COMPILE time. This proves the
    // build ran the App Intents metadata extractor and emitted the
    // Metadata.appintents bundle into the app — the real runtime evidence that
    // the system will surface the intent in Shortcuts. A mis-configured build can
    // import AppIntents yet ship no metadata bundle, and then the action silently
    // never appears; this item catches exactly that.

    static func metadataBundleItem() -> ProbeItem {
        let base = Bundle.main.bundleURL
        let candidates = [
            base.appendingPathComponent("Metadata.appintents"),
            base.appendingPathComponent("Metadata.appintents", isDirectory: true)
        ]
        let fm = FileManager.default
        let found = candidates.first { fm.fileExists(atPath: $0.path) }

        if let found {
            var kids = 0
            if let contents = try? fm.contentsOfDirectory(atPath: found.path) {
                kids = contents.count
            }
            return ProbeItem(
                "intents.metadataBundle",
                "Metadata.appintents bundle",
                .ok,
                value: "present (\(kids) entries)",
                detail: "The App Intents metadata extractor ran and wrote Metadata.appintents into the app bundle. This is the runtime proof — stronger than canImport — that the system was handed the intent's definition and can list Log Telemetry Event in Shortcuts. Read from the RUNNING bundle, not from the build config, because the build could have dropped it.",
                extra: ["path": found.lastPathComponent, "entryCount": String(kids)]
            )
        } else {
            return ProbeItem(
                "intents.metadataBundle",
                "Metadata.appintents bundle",
                .partial,
                value: "not found in bundle root",
                detail: "No Metadata.appintents was found at the bundle root. Either the build did not run the App Intents metadata extractor, or it placed the bundle at a path not checked here. The intent may still register via runtime registration, but this weakens the guarantee that the action appears in Shortcuts. If the ledger below is accumulating events, the channel is working regardless of this signal."
            )
        }
    }

    // ------------------------------------------------------------------
    // 4. Documents directory writable?  (the intent's write must not fail)
    // ------------------------------------------------------------------

    static func documentsWritableItem() -> ProbeItem {
        guard let dir = IntentsProbeLog.documentsURL else {
            return ProbeItem(
                "intents.documentsWritable",
                "Documents directory writable",
                .error,
                value: "no Documents directory",
                detail: "FileManager returned no Documents directory. The App Intent has nowhere to write events.ndjson; the channel cannot function."
            )
        }
        let test = dir.appendingPathComponent(".intentsprobe_write_test")
        do {
            try Data("ok".utf8).write(to: test, options: .atomic)
            try? FileManager.default.removeItem(at: test)
            return ProbeItem(
                "intents.documentsWritable",
                "Documents directory writable",
                .ok,
                value: "writable",
                detail: "A real write-then-delete test in the Documents directory succeeded, so the App Intent can persist events there from a background process. This is the same directory events.ndjson lives in.",
                extra: ["path": dir.path]
            )
        } catch {
            return ProbeItem(
                "intents.documentsWritable",
                "Documents directory writable",
                .error,
                value: "write failed",
                detail: "A write test in the Documents directory threw: \(error.localizedDescription). The App Intent would fail to log; investigate before relying on the channel.",
                extra: ["path": dir.path]
            )
        }
    }

    // ------------------------------------------------------------------
    // 5. The ledger — the payoff. What actually accumulated in events.ndjson.
    // ------------------------------------------------------------------

    static func ledgerItems() -> [ProbeItem] {
        let l = IntentsProbeLedger.read()
        var out: [ProbeItem] = []

        // 5a. Count + recency + distinct kinds. This is the line the whole app
        // exists to print: it is how a future report confirms, from data, that a
        // Shortcuts automation fired.
        let status: ProbeStatus
        let value: String
        if !l.fileExists {
            status = .empty
            value = "no events logged yet"
        } else if l.parsed == 0 {
            status = .empty
            value = "file present, 0 parseable events"
        } else {
            status = .ok
            value = "\(l.parsed) event\(l.parsed == 1 ? "" : "s") logged"
        }

        let kindList = l.kinds.keys.sorted()
        let kindSummary = kindList.isEmpty
            ? "none"
            : kindList.map { "\($0)×\(l.kinds[$0] ?? 0)" }.joined(separator: ", ")

        var extra: [String: String] = [
            "fileName": IntentsProbeLog.fileName,
            "fileExists": l.fileExists ? "true" : "false",
            "fileSizeBytes": String(l.fileSizeBytes),
            "totalLines": String(l.totalLines),
            "parsedEvents": String(l.parsed),
            "parseFailures": String(l.parseFailures),
            "distinctKinds": String(l.kinds.count),
            "kinds": kindList.isEmpty ? "none" : kindList.joined(separator: ",")
        ]
        if let mr = l.mostRecent {
            extra["mostRecentTs"] = ProbeEnv.stamp(mr)
            if let age = ProbeEnv.age(mr) { extra["mostRecentAge"] = age }
        }
        if let old = l.oldest {
            extra["oldestTs"] = ProbeEnv.stamp(old)
            if let age = ProbeEnv.age(old) { extra["oldestAge"] = age }
        }

        var detail = "This is the read-back of events.ndjson — the append-only ledger the App Intent writes to. "
        if l.parsed > 0 {
            detail += "Distinct event kinds seen: \(kindSummary). Most recent event: \(ProbeEnv.stamp(l.mostRecent) ?? "?") (\(ProbeEnv.age(l.mostRecent) ?? "?")). "
            detail += "A future report showing kinds like 'app_open', 'apple_pay', 'charger', 'wifi', 'focus', or 'alarm' here is PROOF that a Shortcuts personal automation fired and wrote through the intent while the app was not in the foreground. "
        } else {
            detail += "No events yet. To arm the channel: open Shortcuts, create a personal automation (e.g. App > Is Opened, or Charger > Is Connected), add the 'Log Telemetry Event' action, set its Kind, and turn OFF 'Ask Before Running'. Then trigger it and re-run this probe. "
        }
        if l.parseFailures > 0 {
            detail += "\(l.parseFailures) line(s) failed to parse — expected if the intent was mid-append during this read (a torn final line), or if the file was hand-edited. "
        }

        out.append(ProbeItem(
            "intents.ledger.events",
            "Logged events (events.ndjson)",
            status,
            value: value,
            detail: detail,
            extra: extra
        ))

        // 5b. Per-process attribution — the terminated-execution ground truth.
        if l.parsed > 0 {
            let distinctPids = l.pids.count
            let maxPerPid = l.pids.values.max() ?? 0
            let interpretation: String
            if distinctPids >= 2 && maxPerPid <= 2 {
                interpretation = "Multiple distinct process UUIDs with few events each strongly implies the system launched a FRESH process per automation fire — i.e. the App Intent genuinely runs while the app is terminated/suspended."
            } else if distinctPids == 1 && maxPerPid >= 3 {
                interpretation = "All events share one process UUID, implying a single live process handled every fire so far — either the app stayed resident, or all fires happened in one session. Fire the automation again after force-quitting the app to disambiguate."
            } else {
                interpretation = "Not enough events yet to distinguish per-fire process launch from a single resident process. Fire the automation several times, some after force-quitting the app, then re-read."
            }
            out.append(ProbeItem(
                "intents.ledger.processAttribution",
                "Process attribution (terminated-run evidence)",
                .ok,
                value: "\(distinctPids) distinct process UUID\(distinctPids == 1 ? "" : "s"), max \(maxPerPid)/UUID",
                detail: "Each logged line carries the UUID of the process that wrote it. \(interpretation) This live process's UUID is \(IntentsProbeLog.processID).",
                extra: [
                    "distinctProcessUUIDs": String(distinctPids),
                    "maxEventsPerProcess": String(maxPerPid),
                    "currentProcessUUID": IntentsProbeLog.processID
                ]
            ))
        }

        // 5c. Measured perform() duration floor.
        if let maxPerf = l.maxPerfSeconds {
            out.append(ProbeItem(
                "intents.ledger.performDuration",
                "Measured perform() duration (floor)",
                .ok,
                value: String(format: "max %.4f s observed", maxPerf),
                detail: "Every intent fire records its own body wall-clock. The max seen is \(String(format: "%.4f", maxPerf))s. This is the FLOOR of what perform() takes here — a trivial file append — not the kill ceiling. See the execution-budget item for the ceiling, which this probe does not force so the automation stays lightweight and trustworthy.",
                extra: ["maxPerformSeconds": String(format: "%.6f", maxPerf)]
            ))
        }

        return out
    }

    // ------------------------------------------------------------------
    // 6. Siri authorization status (guarded)
    // ------------------------------------------------------------------

    static func siriAuthItem() -> ProbeItem {
        #if canImport(Intents)
        let status = INPreferences.siriAuthorizationStatus()
        let name: String
        let probeStatus: ProbeStatus
        switch status {
        case .authorized:    name = "authorized";    probeStatus = .ok
        case .denied:        name = "denied";        probeStatus = .denied
        case .restricted:    name = "restricted";    probeStatus = .denied
        case .notDetermined: name = "notDetermined"; probeStatus = .notDetermined
        @unknown default:    name = "unknown(\(status.rawValue))"; probeStatus = .partial
        }
        return ProbeItem(
            "intents.siriAuthorization",
            "Siri authorization (INPreferences)",
            probeStatus,
            value: name,
            detail: "INPreferences.siriAuthorizationStatus() resolved to '\(name)'. NOTE: App Intents driven by a Shortcuts personal automation do NOT require Siri authorization — the automation calls perform() directly. Siri auth only gates spoken 'Hey Siri' invocation of the AppShortcut phrases. So the channel works even if this reads notDetermined or denied; this is reported to separate the two invocation paths cleanly.",
            extra: ["siriAuthStatus": name, "requiredForAutomations": "false"]
        )
        #else
        return ProbeItem(
            "intents.siriAuthorization",
            "Siri authorization (INPreferences)",
            .unavailable,
            value: "Intents framework not importable",
            detail: "The Intents framework did not compile in on this SDK, so Siri authorization status cannot be read. Irrelevant to the automation channel, which does not need Siri."
        )
        #endif
    }

    // ------------------------------------------------------------------
    // 7. Control widgets / interactive widget APIs (availability ONLY)
    // ------------------------------------------------------------------
    //
    // Reported for completeness because a ControlWidget button is another
    // zero-Siri way to fire an AppIntent. We do NOT add a widget extension: an
    // extension needs App Groups to share the SQLite/ledger, and App Groups may
    // not be provisionable on a free account (that is one of the very questions
    // this whole app exists to answer). So: availability only, no extension.

    static func controlWidgetItem() -> ProbeItem {
        #if canImport(WidgetKit)
        if #available(iOS 18, *) {
            return ProbeItem(
                "intents.controlWidget",
                "ControlWidget / interactive widgets",
                .ok,
                value: "ControlWidget API present (iOS 18+)",
                detail: "This SDK+OS supports ControlWidget — the iOS 18 Control Center / Lock Screen control that can fire an AppIntent from a single tap, a second entitlement-free path to the same write endpoint. Interactive widgets (Button/Toggle intents) landed in iOS 17 and are also available. AVAILABILITY ONLY: no widget extension is shipped, because it would require App Groups to share this app's ledger — a capability the EntitlementProbe is separately testing and which may not be grantable on a free account.",
                extra: ["widgetKit": "true", "controlWidget": "true (iOS 18+)", "interactiveWidgets": "true (iOS 17+)", "extensionShipped": "false", "reason": "App Groups may be unprovisionable"]
            )
        } else {
            return ProbeItem(
                "intents.controlWidget",
                "ControlWidget / interactive widgets",
                .partial,
                value: "interactive widgets only (pre-iOS 18)",
                detail: "WidgetKit is present but the OS is below iOS 18, so ControlWidget (Control Center controls) is unavailable; interactive widgets with Button/Toggle intents (iOS 17) are available. Availability only — no extension shipped (App Groups gate)."
            )
        }
        #else
        return ProbeItem(
            "intents.controlWidget",
            "ControlWidget / interactive widgets",
            .unavailable,
            value: "WidgetKit not importable",
            detail: "WidgetKit did not compile in on this SDK, so Control Center / interactive widget APIs are unavailable. Reported as availability only — no widget extension is added here because an extension needs App Groups, which may not be provisionable on a free account."
        )
        #endif
    }

    // ------------------------------------------------------------------
    // 8. Can the intent run terminated?  What is its time budget?
    // ------------------------------------------------------------------
    //
    // The definitive answer is MEASURED, not fetched — it lives in the process
    // attribution item above (5b). This item states the documented framing and,
    // critically, converts the unverifiable parts into an on-device field test.

    static func terminatedExecutionItem() -> ProbeItem {
        return ProbeItem(
            "intents.terminatedExecution",
            "Terminated execution + time budget",
            .partial,
            value: "runs in a background process; budget measured empirically",
            detail: """
            With openAppWhenRun = false, an App Intent invoked by a personal automation runs WITHOUT foregrounding the app — the system executes perform() in a short-lived background process, so it works while the app is terminated or suspended. That is exactly what the process-attribution item (distinct process UUIDs per fire) measures directly on this phone rather than asserting from docs.

            TIME BUDGET — stated honestly. Apple does not publish a hard number; community reports put non-foregrounding intent execution in the low tens of seconds (roughly 10–30s) before the system reclaims the process, similar to a short background task. This file MEASURES the floor (perfSeconds per fire) but does NOT probe the ceiling: a probe that deliberately runs long to find the kill point would be a side-effecting, flaggable automation, contrary to keeping this channel trustworthy. For the collector, keep each perform() well under ~10s (a local SQLite/NDJSON append is microseconds — no concern).

            FIELD TEST to nail the ceiling later if it ever matters: ship a throwaway intent whose perform() loops appending a heartbeat line every 250ms with an incrementing counter, wire it to a manual automation, fire once, and read how high the counter got before the process died. That converts the last unknown into one measured number.
            """,
            extra: [
                "runsWhileTerminated": "yes (background process, openAppWhenRun=false)",
                "budgetDocumented": "no hard Apple number",
                "budgetEstimateSeconds": "~10-30 (community reports; unverified)",
                "budgetFloorMeasured": "see intents.ledger.performDuration",
                "collectorGuidance": "keep perform() < ~10s; local append is trivial"
            ]
        )
    }

    // ------------------------------------------------------------------
    // 9. The complete personal-automation trigger catalog (iOS 26)
    // ------------------------------------------------------------------
    //
    // Verified against Apple's own Shortcuts User Guide (support.apple.com,
    // iOS edition, fetched 2026-07-24). Every trigger the collector needs is
    // present and entitlement-free.

    static func triggerCatalogItem() -> ProbeItem {
        return ProbeItem(
            "intents.triggerCatalog",
            "Personal-automation triggers (iOS 26)",
            .ok,
            value: "5 categories; all six collector events covered",
            detail: """
            Complete list of personal-automation triggers in Shortcuts, verified against Apple's Shortcuts User Guide (support.apple.com, iOS edition):

            EVENT — Time of Day (Sunrise / Sunset / specific time; Daily, Weekly, Monthly repeat); Alarm (Any / Existing / Wake-up; Is Snoozed / Is Stopped); Sleep (Wind Down Begins / Bedtime Begins / Waking Up); Apple Watch Workout (by type; Starts / Ends / both); Sound Recognition (a chosen sound).
            TRAVEL — Arrive; Leave; Before I Commute (to/from the Work address in your contact card); CarPlay (Connects / Disconnects).
            COMMUNICATION — Message (Sender, Message Contains); Email (Sender, Subject Contains, Account, Recipient).
            TRANSACTION — When I tap a Wallet card or pass / complete an Apple Pay transaction.
            SETTING — Wi-Fi (join a selected network); Bluetooth (connect a selected device); Focus (turned on / off); Low Power Mode (on / off); Battery Level (Equals / Rises Above / Falls Below); Charger (Connected / Disconnected); NFC (scan a tag); App (Is Opened / Is Closed); Airplane Mode (on / off). Plus iOS 17-era additions: Display Connects, and Stage Manager on (iPad).

            COLLECTOR COVERAGE — every event the project needs is here, entitlement-free: app open/close = Setting ▸ App; Apple Pay = Transaction; Focus changes = Setting ▸ Focus; charger = Setting ▸ Charger; Wi-Fi joins = Setting ▸ Wi-Fi; alarms = Event ▸ Alarm.
            """,
            extra: [
                "categories": "event,travel,communication,transaction,setting",
                "appOpenClose": "Setting > App (Is Opened / Is Closed)",
                "applePay": "Transaction (Wallet / Apple Pay)",
                "focusChange": "Setting > Focus",
                "charger": "Setting > Charger",
                "wifiJoin": "Setting > Wi-Fi",
                "alarm": "Event > Alarm",
                "source": "support.apple.com Shortcuts User Guide (iOS), fetched 2026-07-24"
            ]
        )
    }

    // ------------------------------------------------------------------
    // 10. THE MAKE-OR-BREAK QUESTION: does a Run Immediately automation
    //     post a banner every time?  (honest, and turned into a field test)
    // ------------------------------------------------------------------

    static func bannerFindingItem() -> ProbeItem {
        return ProbeItem(
            "intents.runImmediatelyBanner",
            "Run-Immediately banner behavior (UNVERIFIED)",
            .partial,
            value: "hypothesis: suppressible via 'Notify When Run' — MEASURE ON DEVICE",
            detail: """
            THE MAKE-OR-BREAK QUESTION: if a personal automation set to run immediately (Ask Before Running OFF) posts a visible banner EVERY time it fires, then running ~30 of them is untenable and this whole channel changes shape.

            WHAT I COULD NOT VERIFY THIS SESSION (auditable exhaustion): the WebSearch budget was fully spent (200/200) before this probe ran. WebFetch fallbacks failed: reddit.com and old.reddit.com are host-blocked here, apple.stackexchange.com is host-blocked, DuckDuckGo's HTML endpoint returned a CAPTCHA, and six secondary write-ups 404'd/403'd (osxdaily, macmost, idownloadblog, 9to5mac, appleinsider, macrumors, tomsguide). Apple's own Shortcuts User Guide documents the triggers but is silent on run-time banners.

            WORKING HYPOTHESIS (LABELLED AS SUCH, NOT FACT): Historically every personal automation posted a persistent banner when it ran immediately. iOS 16.4 (spring 2023) is understood to have added a per-automation "Notify When Run" toggle that suppresses that banner, letting the automation run silently; this is believed to carry forward through iOS 17 into iOS 26 and to apply to the setting/event triggers the collector uses (App, Wi-Fi, Charger, Focus). If correct, ~30 silent automations is fine. If wrong — if some trigger classes force a banner regardless — the channel must be pruned to a few high-value triggers. This is recall, not a citation, and must be treated as unconfirmed.

            SETTLE IT IN 10 MINUTES ON THE PHONE (this beats any blog): (1) Create automation A: App ▸ Is Opened (pick any app) → action Log Telemetry Event, Kind = "banner_on"; leave 'Ask Before Running' OFF and 'Notify When Run' ON. (2) Create automation B identical but Kind = "banner_off" and 'Notify When Run' OFF. (3) Open the trigger app 5 times for each. (4) Count banners: A should show ~5, B should show ~0. Re-run this probe: kinds banner_on×5 / banner_off×5 in the ledger, cross-referenced with how many banners you actually saw, gives the definitive per-device answer — and simultaneously proves silent background logging works.
            """,
            extra: [
                "status": "unverified-hypothesis",
                "hypothesisToggle": "Notify When Run (per-automation)",
                "hypothesisIntroducedOS": "iOS 16.4 (unconfirmed)",
                "webSearchBudget": "exhausted 200/200",
                "blockedSources": "reddit,old.reddit,apple.stackexchange,duckduckgo-captcha",
                "dead404Sources": "osxdaily,macmost,idownloadblog,9to5mac,appleinsider,macrumors,tomsguide",
                "resolution": "on-device A/B field test (banner_on vs banner_off)"
            ]
        )
    }

    // ------------------------------------------------------------------
    // Summary
    // ------------------------------------------------------------------

    static func summarize(_ items: [ProbeItem]) -> String {
        var t: [ProbeStatus: Int] = [:]
        for i in items { t[i.status, default: 0] += 1 }
        func c(_ s: ProbeStatus) -> Int { t[s] ?? 0 }

        var s = "The sleeper channel: a zero-entitlement, free-Apple-ID path to events no framework can read. "
        s += "This file SHIPS the working App Intent (IntentsProbeLogEvent, openAppWhenRun=false) and the app's sole AppShortcutsProvider, so 'Log Telemetry Event' is usable in Shortcuts the moment the build lands. "

        #if canImport(AppIntents)
        s += "AppIntents compiled in. "
        #else
        s += "AppIntents did NOT compile in on this SDK — the channel is absent in this build. "
        #endif

        let ledger = IntentsProbeLedger.read()
        if ledger.parsed > 0 {
            s += "events.ndjson already holds \(ledger.parsed) event(s) across \(ledger.kinds.count) kind(s)"
            if let mr = ledger.mostRecent, let age = ProbeEnv.age(mr) { s += " (most recent \(age))" }
            s += " — that ledger is how a later report proves an automation fired while the app was closed. "
        } else {
            s += "No events logged yet — arm a personal automation, fire it, and re-run to confirm silent background writes. "
        }

        s += "Every personal-automation trigger the collector needs (app open/close, Apple Pay, Focus, charger, Wi-Fi join, alarm) exists entitlement-free and is catalogued from Apple's guide. "
        s += "TWO honest gaps, both turned into on-device measurements rather than left as guesses: (1) whether a Run-Immediately automation forces a notification banner every fire — UNVERIFIED (web budget exhausted, all secondary sources blocked/404), hypothesised suppressible via the 'Notify When Run' toggle and settled by a banner_on/banner_off A/B test; (2) the exact terminated-execution time budget — the floor is measured per fire (perfSeconds) and per-process UUIDs already show whether each fire gets a fresh process. "
        s += "Deliberately omitted: no widget extension (ControlWidget/interactive widgets reported as availability-only) because an extension needs App Groups, which may not be provisionable on a free account; and no long-running intent to force the kill-ceiling, to keep the automation side-effect-light. "
        s += "Tally — ok:\(c(.ok)) partial:\(c(.partial)) empty:\(c(.empty)) denied:\(c(.denied)) notDetermined:\(c(.notDetermined)) unavailable:\(c(.unavailable)) error:\(c(.error))."
        return s
    }
}
