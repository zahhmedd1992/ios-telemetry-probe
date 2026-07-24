import Foundation
import UIKit
import BackgroundTasks
import Darwin

// MARK: - BackgroundProbe
//
// Continuity IS the product. Every other probe in this app answers "can I read
// X once, while the user is looking at the screen?". This one answers the only
// question that decides whether a collector exists at all: "will iOS ever run
// my code again when nobody is looking?"
//
// Four independent lines of evidence, kept separate because they routinely
// disagree:
//
//   1. WHAT THE SHIPPED BUNDLE DECLARES — UIBackgroundModes and
//      BGTaskSchedulerPermittedIdentifiers, read at runtime from the running
//      app's Info.plist, twice: once via Bundle.main.infoDictionary (what the
//      loader sees) and once by parsing the raw Info.plist bytes off disk.
//      Sideloadly and every other re-signing tool rewrites the Info.plist. If
//      those two views disagree, the deploy pipeline is silently editing our
//      capabilities and the whole collector design is built on sand.
//
//   2. WHAT THE USER HAS ALLOWED — UIApplication.backgroundRefreshStatus.
//      One toggle in Settings, and the system stops relaunching this app for
//      BGTaskScheduler, for silent push, for HealthKit background delivery AND
//      for every CoreLocation event including significant-change and region
//      monitoring. It is the single highest-leverage switch on the device and
//      it is invisible from inside CoreLocation.
//
//   3. WHAT THE SCHEDULER ACCEPTS — real BGAppRefreshTaskRequest and
//      BGProcessingTaskRequest submissions, with the exact error if they are
//      rejected, plus the pending queue read BEFORE and AFTER submission. The
//      "before" read is the interesting one: it says what survived since the
//      last run.
//
//   4. WHAT ACTUALLY HAPPENED — a append-only NDJSON launch ledger in
//      Documents. Every documentation claim about background wakeups on iOS is
//      contested, version-stale, or both. Over days, this file is the only
//      thing in the project that can settle the argument empirically for THIS
//      phone, THIS Apple ID and THIS signing tier.
//
// DELIBERATE OMISSION — this probe does NOT call
// BGTaskScheduler.shared.register(forTaskWithIdentifier:using:launchHandler:).
// That is not timidity, it is the API contract. The BackgroundTasks header is
// explicit: "You must register launch handlers before your application finishes
// launching. Attempting to register a handler after launch or multiple handlers
// for the same identifier is an error", and "The system kills the app on the
// second registration of the same task identifier." Late registration raises
// NSInternalInconsistencyException from BGTaskScheduler.m:185 ("All launch
// handlers must be registered before application finishes launching"), which is
// an Objective-C exception — uncatchable from Swift, and fatal to all eleven
// sections of this report. This probe runs from a button tap, which is by
// definition after launch.
//
// Instead the registration is implemented in full, once, in
// `BackgroundProbeScheduler.installAtLaunch(launchOptions:)`, and the probe
// reports whether that hook was ever invoked. Wiring it up is a one-line change
// in ProbeApp.swift:
//
//     @main struct ProbeApp: App {
//         init() { BackgroundProbeScheduler.installAtLaunch(launchOptions: nil) }
//         ...
//     }
//
// Until that line exists, no BGTask can ever RUN — but submissions and the
// pending queue are still fully measurable, and they are what this section
// measures.

// MARK: - Identifiers

enum BackgroundProbeIDs {
    /// Must match BGTaskSchedulerPermittedIdentifiers in Info.plist exactly.
    static let refresh = "com.zacharyahmed.telemetryprobe.refresh"
    static let process = "com.zacharyahmed.telemetryprobe.process"

    /// Apple's documented ceilings (BGTaskScheduler.h): "There can be a total of
    /// 1 refresh task and 10 processing tasks scheduled at any time."
    static let maxPendingRefresh = 1
    static let maxPendingProcessing = 10

    static let defaultsPrefix = "BackgroundProbe."
}

// MARK: - Launch-time hook (the ONLY safe place to register)

/// Everything in here is designed to be called from `ProbeApp.init()` or from
/// `application(_:didFinishLaunchingWithOptions:)`, i.e. BEFORE the app finishes
/// launching. It is idempotent and lock-guarded, so a double call cannot trip
/// the "second registration kills the app" rule even if two code paths call it.
///
/// The probe never calls `register` itself — it only reads the state this type
/// records, so the section can report ground truth about registration without
/// risking the uncatchable ObjC exception described at the top of this file.
enum BackgroundProbeScheduler {

    private static let lock = NSLock()
    private static var installCalled = false
    private static var installedAt: Date?
    private static var registered: [String: Bool] = [:]   // identifier -> register() return value
    private static var launchState: String?
    private static var launchOptionKeys: [String] = []

    /// Call from `ProbeApp.init()`. Safe to call more than once; only the first
    /// call registers anything.
    ///
    /// `@MainActor` because `SwiftUI.App.init()` is already main-actor isolated
    /// and because the application-state read below is only meaningful there.
    ///
    /// - Parameter launchOptions: pass the dictionary from
    ///   `application(_:didFinishLaunchingWithOptions:)` if an AppDelegate is
    ///   in play. `UIApplication.LaunchOptionsKey.location` present here is the
    ///   definitive, documented proof that CoreLocation woke the app.
    @MainActor
    @discardableResult
    static func installAtLaunch(launchOptions: [AnyHashable: Any]? = nil) -> Bool {
        lock.lock()
        if installCalled {
            lock.unlock()
            return false
        }
        installCalled = true
        installedAt = Date()
        launchOptionKeys = (launchOptions?.keys.map { "\($0)" } ?? []).sorted()
        lock.unlock()

        // Record the state the process was in the instant it came up. This is
        // the ONLY moment at which "did iOS launch me into the background?" is
        // answerable; by the time any UI appears the answer is gone.
        let state = BackgroundProbeUI.stateName(UIApplication.shared.applicationState.rawValue)
        lock.lock(); launchState = state; lock.unlock()

        let refreshOK = registerOne(BackgroundProbeIDs.refresh, reason: "bgtask.refresh")
        let processOK = registerOne(BackgroundProbeIDs.process, reason: "bgtask.process")

        BackgroundProbeLedger.appendLine(
            reason: "launch",
            extra: [
                "launchState": state,
                "launchOptionKeys": launchOptionKeys.joined(separator: ","),
                "registeredRefresh": refreshOK ? "1" : "0",
                "registeredProcess": processOK ? "1" : "0"
            ]
        )
        return true
    }

    private static func registerOne(_ identifier: String, reason: String) -> Bool {
        // register() returns NO (not an exception) when the identifier is absent
        // from BGTaskSchedulerPermittedIdentifiers — that return value is itself
        // a measurement of the shipped plist, so it is recorded.
        let ok = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: nil
        ) { task in
            // This is the payload the real collector replaces. For the probe the
            // only job is to leave permanent, timestamped evidence that iOS
            // really did wake this app with nobody watching.
            let started = Date()
            task.expirationHandler = {
                BackgroundProbeLedger.appendLine(
                    reason: reason + ".expired",
                    extra: ["ranForSec": String(format: "%.2f", Date().timeIntervalSince(started))]
                )
                task.setTaskCompleted(success: false)
            }
            BackgroundProbeLedger.appendLine(
                reason: reason,
                extra: ["identifier": identifier]
            )
            // Immediately reschedule: a BGTask request is consumed when it runs,
            // so a collector that does not resubmit gets exactly one wake, ever.
            BackgroundProbeScheduler.resubmitQuietly(identifier: identifier)
            task.setTaskCompleted(success: true)
        }
        lock.lock(); registered[identifier] = ok; lock.unlock()
        return ok
    }

    /// Fire-and-forget resubmission used from inside a launch handler.
    static func resubmitQuietly(identifier: String) {
        if identifier == BackgroundProbeIDs.refresh {
            let r = BGAppRefreshTaskRequest(identifier: identifier)
            r.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
            try? BGTaskScheduler.shared.submit(r)
        } else {
            let r = BGProcessingTaskRequest(identifier: identifier)
            r.requiresNetworkConnectivity = true
            r.requiresExternalPower = false
            r.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
            try? BGTaskScheduler.shared.submit(r)
        }
    }

    // Read-only accessors used by the probe.

    static var didInstall: Bool {
        lock.lock(); defer { lock.unlock() }
        return installCalled
    }

    static var installTime: Date? {
        lock.lock(); defer { lock.unlock() }
        return installedAt
    }

    static var registrationResults: [String: Bool] {
        lock.lock(); defer { lock.unlock() }
        return registered
    }

    static var recordedLaunchState: String? {
        lock.lock(); defer { lock.unlock() }
        return launchState
    }

    static var recordedLaunchOptionKeys: [String] {
        lock.lock(); defer { lock.unlock() }
        return launchOptionKeys
    }
}

// MARK: - UIKit access helpers

/// A plain-data, `Sendable` snapshot of everything UIKit will only hand over on
/// the main actor. Gathered once, up front, under a timeout, so that the rest of
/// the probe never has to hop actors again.
struct BackgroundProbeUISnapshot: Sendable {
    var applicationStateRaw: Int = -1
    var applicationState: String = "unknown"
    var backgroundRefreshRaw: Int = -1
    var backgroundRefresh: String = "unknown"
    var backgroundTimeRemaining: Double = -1
    var backgroundTimeRemainingAfterBegin: Double = -1
    var beginBackgroundTaskGranted: Bool = false
    var beginBackgroundTaskIdentifier: Int = 0
    var protectedDataAvailable: Bool = false
    var batteryLevel: Float = -1
    var batteryStateRaw: Int = -1
    var isLowPowerMode: Bool = false
    var thermalStateRaw: Int = -1
    var gathered: Bool = false
}

enum BackgroundProbeUI {

    static func stateName(_ raw: Int) -> String {
        switch raw {
        case 0: return "active"
        case 1: return "inactive"
        case 2: return "background"
        default: return "unknown(\(raw))"
        }
    }

    static func refreshName(_ raw: Int) -> String {
        switch raw {
        case 0: return "restricted"
        case 1: return "denied"
        case 2: return "available"
        default: return "unknown(\(raw))"
        }
    }

    static func batteryStateName(_ raw: Int) -> String {
        switch raw {
        case 0: return "unknown"
        case 1: return "unplugged"
        case 2: return "charging"
        case 3: return "full"
        default: return "unknown(\(raw))"
        }
    }

    static func thermalName(_ raw: Int) -> String {
        switch raw {
        case 0: return "nominal"
        case 1: return "fair"
        case 2: return "serious"
        case 3: return "critical"
        default: return "unknown(\(raw))"
        }
    }

    @MainActor
    static func snapshot() -> BackgroundProbeUISnapshot {
        var s = BackgroundProbeUISnapshot()
        let app = UIApplication.shared

        s.applicationStateRaw = app.applicationState.rawValue
        s.applicationState = stateName(s.applicationStateRaw)
        s.backgroundRefreshRaw = app.backgroundRefreshStatus.rawValue
        s.backgroundRefresh = refreshName(s.backgroundRefreshRaw)
        s.protectedDataAvailable = app.isProtectedDataAvailable
        s.backgroundTimeRemaining = app.backgroundTimeRemaining

        // Take a REAL background task assertion and re-read the budget. In the
        // foreground the value does not move off the sentinel — that
        // non-movement is the expected result and is reported as such, not as a
        // failure. The assertion is ended immediately either way.
        let box = BackgroundProbeTaskBox()
        let ident = app.beginBackgroundTask(withName: "BackgroundProbe.budget") {
            // The expiration handler is a plain, non-isolated block, so hop
            // explicitly rather than touching UIApplication from it.
            Task { @MainActor in box.end() }
        }
        box.identifier = ident
        s.beginBackgroundTaskGranted = (ident != .invalid)
        s.beginBackgroundTaskIdentifier = ident.rawValue
        s.backgroundTimeRemainingAfterBegin = app.backgroundTimeRemaining
        box.end()

        // batteryLevel is a hard -1 unless monitoring is switched on first.
        let dev = UIDevice.current
        if !dev.isBatteryMonitoringEnabled { dev.isBatteryMonitoringEnabled = true }
        s.batteryLevel = dev.batteryLevel
        s.batteryStateRaw = dev.batteryState.rawValue

        let pi = ProcessInfo.processInfo
        s.isLowPowerMode = pi.isLowPowerModeEnabled
        s.thermalStateRaw = pi.thermalState.rawValue

        s.gathered = true
        return s
    }
}

/// Holds a UIBackgroundTaskIdentifier so the expiration handler can reference it
/// without the classic capture-before-assignment bug, and guarantees
/// `endBackgroundTask` runs exactly once even if the handler also fires.
final class BackgroundProbeTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var ended = false
    var identifier: UIBackgroundTaskIdentifier = .invalid

    @MainActor
    func end() {
        lock.lock()
        if ended { lock.unlock(); return }
        ended = true
        let id = identifier
        lock.unlock()
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
    }
}

/// Single-resume guard for continuation safety.
final class BackgroundProbeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

// MARK: - Process / boot timing (public POSIX, no private API)

enum BackgroundProbeSys {

    /// Device boot time. NOTE: iOS recomputes this from the monotonic clock, so
    /// consecutive reads can differ by a second or two. Never use it raw as an
    /// identity key — use `bootKey` which rounds to the nearest minute.
    static func bootTime() -> Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        let r = sysctl(&mib, 2, &tv, &size, nil, 0)
        guard r == 0, tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }

    /// This process's start time — i.e. when THIS launch of the app happened.
    /// Combined with the ledger it separates "the app was already running" from
    /// "iOS started a fresh process for this event".
    static func processStartTime() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let r = sysctl(&mib, 4, &info, &size, nil, 0)
        guard r == 0 else { return nil }
        let tv = info.kp_proc.p_starttime
        guard tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }

    /// Reboot identity, rounded to the minute so clock jitter cannot fabricate
    /// phantom reboots in the ledger.
    static func bootKey(_ d: Date?) -> String {
        guard let d else { return "unknown" }
        let rounded = (d.timeIntervalSince1970 / 60.0).rounded()
        return String(Int(rounded))
    }
}

// MARK: - Formatting

enum BackgroundProbeFmt {

    static func dur(_ seconds: Double) -> String {
        if !seconds.isFinite { return "∞" }
        let s = abs(seconds)
        if s < 1 { return String(format: "%.0f ms", s * 1000) }
        if s < 90 { return String(format: "%.1f s", s) }
        if s < 5400 { return String(format: "%.1f min", s / 60) }
        if s < 172_800 { return String(format: "%.1f hr", s / 3600) }
        return String(format: "%.2f days", s / 86_400)
    }

    static func bytes(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return String(format: "%.1f KB", Double(n) / 1024) }
        return String(format: "%.2f MB", Double(n) / (1024 * 1024))
    }

    /// Detects the "not in the background, budget is meaningless" sentinel that
    /// UIKit returns for backgroundTimeRemaining in the foreground.
    static func isForegroundSentinel(_ v: Double) -> Bool {
        return !v.isFinite || v > 1e30
    }

    static func raw(_ v: Double) -> String {
        if !v.isFinite { return "\(v)" }
        if v > 1e15 { return String(format: "%.6e", v) }
        return String(format: "%.2f", v)
    }
}

// MARK: - Info.plist reading

struct BackgroundProbePlistView {
    var loaderModes: [String] = []
    var loaderIdentifiers: [String] = []
    var rawModes: [String] = []
    var rawIdentifiers: [String] = []
    var rawPlistFound = false
    var rawPlistBytes = 0
    var rawParseError: String?
}

enum BackgroundProbePlist {

    static func read() -> BackgroundProbePlistView {
        var v = BackgroundProbePlistView()
        let b = Bundle.main

        let info = b.infoDictionary ?? [:]
        v.loaderModes = strings(info["UIBackgroundModes"])
        v.loaderIdentifiers = strings(info["BGTaskSchedulerPermittedIdentifiers"])

        // Second, independent view: parse the Info.plist bytes off disk. A
        // re-signing tool that rewrote the plist after the build would show up
        // as a divergence between these two.
        if let url = b.url(forResource: "Info", withExtension: "plist"),
           let data = try? Data(contentsOf: url) {
            v.rawPlistFound = true
            v.rawPlistBytes = data.count
            var fmt = PropertyListSerialization.PropertyListFormat.xml
            do {
                let obj = try PropertyListSerialization.propertyList(
                    from: data, options: [], format: &fmt)
                if let dict = obj as? [String: Any] {
                    v.rawModes = strings(dict["UIBackgroundModes"])
                    v.rawIdentifiers = strings(dict["BGTaskSchedulerPermittedIdentifiers"])
                } else {
                    v.rawParseError = "Info.plist did not decode to a dictionary."
                }
            } catch {
                v.rawParseError = error.localizedDescription
            }
        }
        return v
    }

    private static func strings(_ any: Any?) -> [String] {
        if let a = any as? [String] { return a }
        if let a = any as? [Any] { return a.compactMap { $0 as? String } }
        if let s = any as? String { return [s] }
        return []
    }

    /// Every UIBackgroundMode value that exists, with what it actually buys a
    /// collector. Reported so the section documents the whole option space, not
    /// just the four modes this build happens to declare.
    static let catalogue: [(String, String)] = [
        ("location",
         "Permits continuous location updates (allowsBackgroundLocationUpdates) and shows the blue status bar. NOT required for visits, significant-location-change or region monitoring — those wake the app without it. Setting allowsBackgroundLocationUpdates = true WITHOUT this mode is documented as a fatal error that terminates the app."),
        ("fetch",
         "Legacy UIApplication background fetch, and the prerequisite for BGAppRefreshTaskRequest. Without it, submitting an app-refresh request fails with BGTaskSchedulerErrorCodeNotPermitted (3)."),
        ("processing",
         "Prerequisite for BGProcessingTaskRequest — the several-minutes, plugged-in-and-idle slot used for database maintenance, ML training and bulk sync."),
        ("bluetooth-central",
         "Lets the app keep CBCentralManager connections and be relaunched by CoreBluetooth state restoration when a known peripheral appears. Requires a restoration identifier to actually relaunch."),
        ("remote-notification",
         "Silent (content-available) push. NOT declared in this build, and it needs an aps-environment entitlement plus an APNs push certificate/key from a paid developer account — so it is structurally out of reach at this signing tier."),
        ("audio",
         "Keeps the process alive indefinitely while audio is playing. The classic abuse channel for a keepalive daemon; it does NOT relaunch a terminated app, drains battery visibly, and is not declared here."),
        ("voip",
         "Deprecated as a keepalive; PushKit VoIP pushes now require CallKit reporting or the app is killed. Not usable for telemetry."),
        ("external-accessory",
         "Wakes for MFi accessory traffic."),
        ("bluetooth-peripheral",
         "Acts as a BLE peripheral in the background."),
        ("nearby-interaction",
         "Keeps a UWB NISession alive in the background."),
        ("push-to-talk",
         "PTChannelManager; entitlement-gated and Apple-reviewed.")
    ]
}

// MARK: - BGTaskScheduler interaction

struct BackgroundProbePendingRequest {
    var identifier: String
    var className: String
    var earliestBeginDate: Date?
    var requiresNetworkConnectivity: Bool?
    var requiresExternalPower: Bool?

    var describe: String {
        var s = "\(identifier) [\(className)]"
        if let d = earliestBeginDate {
            s += " earliest=\(ProbeEnv.iso.string(from: d))"
            let delta = d.timeIntervalSinceNow
            s += delta > 0 ? " (in \(BackgroundProbeFmt.dur(delta)))"
                           : " (\(BackgroundProbeFmt.dur(-delta)) ago — eligible now)"
        } else {
            s += " earliest=nil (eligible immediately)"
        }
        if let n = requiresNetworkConnectivity { s += " network=\(n)" }
        if let p = requiresExternalPower { s += " power=\(p)" }
        return s
    }
}

struct BackgroundProbeSubmitResult {
    var submitted: Bool
    var errorDomain: String?
    var errorCode: Int?
    var errorText: String?
    var interpretation: String?

    /// Precomputed so string interpolation never has to contain a closure.
    var codeText: String {
        guard let errorCode else { return "?" }
        return String(errorCode)
    }
    var domainText: String { errorDomain ?? "?" }
}

enum BackgroundProbeTasks {

    static func pending() async -> [BackgroundProbePendingRequest]? {
        let fallback: [BackgroundProbePendingRequest]? = nil
        return await withProbeTimeout(10, fallback: fallback) {
            await withCheckedContinuation { (cont: CheckedContinuation<[BackgroundProbePendingRequest]?, Never>) in
                let once = BackgroundProbeOnce()
                BGTaskScheduler.shared.getPendingTaskRequests { requests in
                    guard once.claim() else { return }
                    var out: [BackgroundProbePendingRequest] = []
                    for r in requests {
                        var item = BackgroundProbePendingRequest(
                            identifier: r.identifier,
                            className: String(describing: type(of: r)),
                            earliestBeginDate: r.earliestBeginDate,
                            requiresNetworkConnectivity: nil,
                            requiresExternalPower: nil
                        )
                        if let p = r as? BGProcessingTaskRequest {
                            item.requiresNetworkConnectivity = p.requiresNetworkConnectivity
                            item.requiresExternalPower = p.requiresExternalPower
                        }
                        out.append(item)
                    }
                    cont.resume(returning: out)
                }
            }
        }
    }

    static func submit(_ request: BGTaskRequest) -> BackgroundProbeSubmitResult {
        do {
            try BGTaskScheduler.shared.submit(request)
            return BackgroundProbeSubmitResult(submitted: true)
        } catch {
            let ns = error as NSError
            return BackgroundProbeSubmitResult(
                submitted: false,
                errorDomain: ns.domain,
                errorCode: ns.code,
                errorText: ns.localizedDescription,
                interpretation: interpret(domain: ns.domain, code: ns.code)
            )
        }
    }

    /// The header enumerates exactly three causes. Code 1 is deliberately
    /// branched on simulator, because there it is expected and says nothing
    /// about the user's settings.
    static func interpret(domain: String, code: Int) -> String {
        guard domain.contains("BGTaskScheduler") else {
            return "Unrecognised error domain \(domain) — not one of the three documented BGTaskScheduler failures."
        }
        switch code {
        case 1:
            if ProbeEnv.isSimulator {
                return "BGTaskSchedulerErrorCodeUnavailable (1). On Simulator this is ALWAYS returned — the Simulator has no background scheduling. It says nothing about the device or the user's settings. Re-run on hardware."
            }
            return "BGTaskSchedulerErrorCodeUnavailable (1) on real hardware. Apple documents exactly one cause that applies to an iPhone app: the user has turned OFF Background App Refresh, globally or for this app. Cross-check the backgroundRefreshStatus item above — if it disagrees, that itself is the finding."
        case 2:
            return "BGTaskSchedulerErrorCodeTooManyPendingTaskRequests (2). The queue is full: Apple allows 1 pending refresh task and 10 pending processing tasks per app. Cancel before resubmitting."
        case 3:
            return "BGTaskSchedulerErrorCodeNotPermitted (3). Either the required UIBackgroundModes entry is missing (\"fetch\" for refresh, \"processing\" for processing) or the identifier is absent from BGTaskSchedulerPermittedIdentifiers. Both are Info.plist facts, which the plist items above measure directly — so this error pins down WHICH of the two was stripped."
        default:
            return "Undocumented BGTaskScheduler error code \(code)."
        }
    }

    /// Runtime class presence sweep. Guards against asserting an API exists on
    /// this SDK/OS when the symbol name cannot be verified at compile time —
    /// NSClassFromString on a public class is fully public API.
    static let classSweep: [(String, String)] = [
        ("BGTaskScheduler", "BackgroundTasks core — iOS 13+"),
        ("BGAppRefreshTaskRequest", "Short (~30 s) opportunistic refresh — iOS 13+"),
        ("BGProcessingTaskRequest", "Long (minutes) maintenance slot — iOS 13+"),
        ("BGHealthResearchTaskRequest", "Health-research variant — iOS 17+, needs a research entitlement"),
        ("BGContinuedProcessingTaskRequest", "User-initiated, progress-reporting continued work — announced for iOS 26"),
        ("BGContinuedProcessingTask", "Task object for the above — iOS 26"),
        ("BGTaskRequest", "Abstract base class")
    ]
}

// MARK: - Launch ledger (append-only NDJSON)

struct BackgroundProbeLedgerStats {
    var totalLines = 0
    var parsedLines = 0
    var malformedLines = 0
    var launchCount = 0
    var first: Date?
    var last: Date?
    var lastGap: TimeInterval?
    var longestGap: TimeInterval?
    var longestGapEndedAt: Date?
    var shortestGap: TimeInterval?
    var meanGap: TimeInterval?
    var byReason: [String: Int] = [:]
    var byState: [String: Int] = [:]
    var backgroundLaunches = 0
    var distinctBoots = 0
    var fileBytes = 0
    var truncatedRead = false
}

enum BackgroundProbeLedger {

    static let fileName = "launches.ndjson"

    static var url: URL? {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(fileName)
    }

    /// Append one NDJSON record. Append-only via FileHandle.seekToEnd — never
    /// read-modify-write, because a crash mid-write would destroy the only
    /// irreplaceable artifact this project produces.
    ///
    /// Returns nil on success, or an error string.
    @discardableResult
    static func appendLine(reason: String, extra: [String: String]) -> String? {
        guard let url else { return "Documents directory unavailable." }

        var record: [String: Any] = [
            "ts": ProbeEnv.iso.string(from: Date()),
            "reason": reason,
            "bootKey": BackgroundProbeSys.bootKey(BackgroundProbeSys.bootTime()),
            "procStart": BackgroundProbeSys.processStartTime().map { ProbeEnv.iso.string(from: $0) } ?? "",
            "uptimeSec": Int(ProcessInfo.processInfo.systemUptime),
            // ProcessInfo, not UIDevice: this runs off the main actor and
            // UIDevice is main-actor isolated in current SDKs.
            "sysVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "build": (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?",
            "lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled ? 1 : 0,
            "thermal": ProcessInfo.processInfo.thermalState.rawValue
        ]
        for (k, v) in extra { record[k] = v }

        guard let data = try? JSONSerialization.data(withJSONObject: record,
                                                     options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8) else {
            return "Failed to encode ledger record."
        }
        line += "\n"
        guard let bytes = line.data(using: .utf8) else { return "Failed to encode ledger line." }

        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            do { try bytes.write(to: url, options: .atomic) } catch {
                return "Create failed: \(error.localizedDescription)"
            }
            return nil
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: bytes)
        } catch {
            return "Append failed: \(error.localizedDescription)"
        }
        return nil
    }

    /// Reads at most the trailing `maxBytes` of the ledger so an unbounded file
    /// can never blow up memory. Drops the first partial line when truncating.
    static func tail(maxBytes: Int = 4 * 1024 * 1024) -> (Data?, Int, Bool) {
        guard let url,
              let handle = try? FileHandle(forReadingFrom: url) else { return (nil, 0, false) }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return (nil, 0, false) }
        let total = Int(min(size, UInt64(Int.max)))
        if size > UInt64(maxBytes) {
            try? handle.seek(toOffset: size - UInt64(maxBytes))
            guard var d = try? handle.readToEnd() else { return (nil, total, true) }
            if let nl = d.firstIndex(of: 0x0A), nl + 1 < d.endIndex {
                d = Data(d[(nl + 1)...])
            }
            return (d, total, true)
        }
        try? handle.seek(toOffset: 0)
        return (try? handle.readToEnd(), total, false)
    }

    static func stats() -> BackgroundProbeLedgerStats {
        var st = BackgroundProbeLedgerStats()
        let (data, total, truncated) = tail()
        st.fileBytes = total
        st.truncatedRead = truncated
        guard let data, let text = String(data: data, encoding: .utf8) else { return st }

        var launchTimes: [Date] = []
        var boots = Set<String>()

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            st.totalLines += 1
            guard let lineData = rawLine.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData),
                  let dict = obj as? [String: Any] else {
                st.malformedLines += 1
                continue
            }
            st.parsedLines += 1

            let reason = (dict["reason"] as? String) ?? "?"
            st.byReason[reason, default: 0] += 1

            if let b = dict["bootKey"] as? String, b != "unknown" { boots.insert(b) }

            if let stateStr = (dict["launchState"] as? String) ?? (dict["state"] as? String) {
                st.byState[stateStr, default: 0] += 1
                if stateStr == "background" { st.backgroundLaunches += 1 }
            } else if reason.hasPrefix("bgtask.") && !reason.hasSuffix(".expired") {
                // A bgtask.* record can only have been written by a launch
                // handler, which the system runs precisely because it woke the
                // app. It carries no state string (it runs off the main actor),
                // so it is counted as an OS-initiated wake on that basis alone.
                st.byState["background", default: 0] += 1
                st.backgroundLaunches += 1
            }

            // Only "launch", "probe" and a real bgtask wake count as a launch
            // event. Two exclusions, both of which would otherwise corrupt the
            // gap statistics permanently:
            //   • "probe.tasks" — the second line each probe run writes, which
            //     carries scheduler telemetry, not a launch.
            //   • "bgtask.*.expired" — the expiration record written seconds
            //     after its own "bgtask.*" record. Counting it would both
            //     double the wake count AND inject a near-zero gap that drags
            //     shortestGap and meanGap down for the life of the file.
            let countsAsLaunch = (reason == "launch" || reason == "probe"
                                  || (reason.hasPrefix("bgtask.")
                                      && !reason.hasSuffix(".expired")))
            if countsAsLaunch,
               let ts = dict["ts"] as? String,
               let d = ProbeEnv.iso.date(from: ts) {
                launchTimes.append(d)
            }
        }

        st.distinctBoots = boots.count
        launchTimes.sort()
        st.launchCount = launchTimes.count
        st.first = launchTimes.first
        st.last = launchTimes.last

        if launchTimes.count >= 2 {
            var gaps: [TimeInterval] = []
            for i in 1..<launchTimes.count {
                gaps.append(launchTimes[i].timeIntervalSince(launchTimes[i - 1]))
            }
            st.lastGap = gaps.last
            var longest: TimeInterval = -1
            var longestIndex = 0
            for (i, g) in gaps.enumerated() where g > longest {
                longest = g
                longestIndex = i
            }
            if longest >= 0 {
                st.longestGap = longest
                let endIdx = longestIndex + 1
                if endIdx >= 0 && endIdx < launchTimes.count {
                    st.longestGapEndedAt = launchTimes[endIdx]
                }
            }
            st.shortestGap = gaps.min()
            st.meanGap = gaps.reduce(0, +) / Double(gaps.count)
        }
        return st
    }
}

// MARK: - Probe

struct BackgroundProbe: TelemetryProbe {
    let key = "background"
    let title = "Background Execution"

    func run() async -> ProbeSection {
        var items: [ProbeItem] = []

        // ------------------------------------------------------------------
        // 0. UIKit snapshot FIRST, then the ledger line, then everything else.
        //    ProbeRunner discards this whole section on a 180 s timeout, so the
        //    irreplaceable artifact (the launch record) is written before any
        //    framework call that could stall.
        // ------------------------------------------------------------------
        let ui = await withProbeTimeout(5, fallback: BackgroundProbeUISnapshot()) {
            await MainActor.run { BackgroundProbeUI.snapshot() }
        }

        let bootTime = BackgroundProbeSys.bootTime()
        let procStart = BackgroundProbeSys.processStartTime()

        let appendError = BackgroundProbeLedger.appendLine(
            reason: "probe",
            extra: [
                // ONE key for application state, deliberately. A record that
                // carried both "state" and "launchState" would read correctly
                // today and silently mis-tally the moment either writer changed
                // meaning — and the ledger is append-only, so a mixed schema
                // can never be cleaned up retroactively.
                "launchState": ui.applicationState,
                "bgRefresh": ui.backgroundRefresh,
                "battery": String(format: "%.2f", ui.batteryLevel),
                "batteryState": BackgroundProbeUI.batteryStateName(ui.batteryStateRaw),
                "protectedData": ui.protectedDataAvailable ? "1" : "0",
                "installHookRan": BackgroundProbeScheduler.didInstall ? "1" : "0"
            ]
        )

        // ------------------------------------------------------------------
        // 1. What the SHIPPED bundle declares
        // ------------------------------------------------------------------
        let plist = BackgroundProbePlist.read()

        let modes = plist.loaderModes
        items.append(ProbeItem(
            "background.plist.modes",
            "UIBackgroundModes (shipped Info.plist)",
            modes.isEmpty ? .empty : .ok,
            value: modes.isEmpty ? "none declared" : modes.joined(separator: ", "),
            detail: modes.isEmpty
                ? "The running app declares NO background modes. Every deferred-execution API below will refuse: BGAppRefreshTaskRequest needs \"fetch\", BGProcessingTaskRequest needs \"processing\", and continuous location needs \"location\". If the source project.yml declares modes and this reads empty, the re-signing step stripped them."
                : "Read at runtime from Bundle.main.infoDictionary — this is what the binary on the phone actually carries, not what the repo says it should. Modes are compared against the raw Info.plist bytes in the next item.",
            extra: [
                "count": String(modes.count),
                "hasFetch": modes.contains("fetch") ? "true" : "false",
                "hasProcessing": modes.contains("processing") ? "true" : "false",
                "hasLocation": modes.contains("location") ? "true" : "false",
                "hasRemoteNotification": modes.contains("remote-notification") ? "true" : "false",
                "hasAudio": modes.contains("audio") ? "true" : "false",
                "hasBluetoothCentral": modes.contains("bluetooth-central") ? "true" : "false"
            ]
        ))

        // Divergence check between the two independent views of the plist.
        if plist.rawPlistFound {
            let modesMatch = Set(plist.rawModes) == Set(plist.loaderModes)
            let idsMatch = Set(plist.rawIdentifiers) == Set(plist.loaderIdentifiers)
            let clean = modesMatch && idsMatch && plist.rawParseError == nil

            var divergeDetail = "The loader's view and the on-disk plist DISAGREE"
            if !modesMatch {
                divergeDetail += " on UIBackgroundModes (raw: " + plist.rawModes.joined(separator: ", ") + ")"
            }
            if !idsMatch {
                divergeDetail += " on BGTaskSchedulerPermittedIdentifiers (raw: "
                    + plist.rawIdentifiers.joined(separator: ", ") + ")"
            }
            divergeDetail += ". "
            if let pe = plist.rawParseError { divergeDetail += "Parse error: " + pe + ". " }
            divergeDetail += "Trust the loader's view for runtime behaviour, but treat the divergence as evidence the signing pipeline is editing the bundle."

            items.append(ProbeItem(
                "background.plist.integrity",
                "Info.plist cross-check (loader vs raw bytes)",
                clean ? .ok : .partial,
                value: clean
                    ? "consistent — \(BackgroundProbeFmt.bytes(plist.rawPlistBytes)) on disk"
                    : "DIVERGENT",
                detail: clean
                    ? "Bundle.main.infoDictionary and the raw Info.plist parsed off disk agree on both UIBackgroundModes and BGTaskSchedulerPermittedIdentifiers. Worth checking every build: Sideloadly, ad-hoc codesign and any re-provisioning tool rewrite the Info.plist, and a stripped background mode fails silently at runtime as a plain BGTaskScheduler error 3 rather than as anything that looks like tampering."
                    : divergeDetail,
                extra: [
                    "rawBytes": String(plist.rawPlistBytes),
                    "rawModes": plist.rawModes.joined(separator: ", "),
                    "rawIdentifiers": plist.rawIdentifiers.joined(separator: ", "),
                    "modesMatch": modesMatch ? "true" : "false",
                    "identifiersMatch": idsMatch ? "true" : "false"
                ]
            ))
        } else {
            items.append(ProbeItem(
                "background.plist.integrity",
                "Info.plist cross-check (loader vs raw bytes)",
                .unavailable,
                value: "raw Info.plist not readable in the bundle",
                detail: "Bundle.main.url(forResource:\"Info\", withExtension:\"plist\") returned nil, so only the loader's view is available. This happens when the plist is stored in a non-standard location in the bundle. Not a failure of the background modes themselves."
            ))
        }

        // Per-mode meaning, for the modes that are actually present.
        for (name, meaning) in BackgroundProbePlist.catalogue where !meaning.isEmpty {
            let present = modes.contains(name)
            items.append(ProbeItem(
                "background.mode.\(name)",
                "Mode: \(name)",
                present ? .ok : .unavailable,
                value: present ? "declared" : "not declared",
                detail: meaning
            ))
        }

        let ids = plist.loaderIdentifiers
        let haveRefreshID = ids.contains(BackgroundProbeIDs.refresh)
        let haveProcessID = ids.contains(BackgroundProbeIDs.process)
        items.append(ProbeItem(
            "background.plist.identifiers",
            "BGTaskSchedulerPermittedIdentifiers",
            ids.isEmpty ? .empty : ((haveRefreshID && haveProcessID) ? .ok : .partial),
            value: ids.isEmpty ? "none declared" : ids.joined(separator: ", "),
            detail: ids.isEmpty
                ? "No permitted identifiers. Every submit() will fail with BGTaskSchedulerErrorCodeNotPermitted (3) and every register() will return NO. BGTaskScheduler is completely dead in this build."
                : "Every identifier listed here REQUIRES a registered launch handler before the app finishes launching — Apple's header is explicit about that, and an identifier with no handler is a wake the system may grant and the app cannot use. Ours: refresh \(haveRefreshID ? "PRESENT" : "MISSING"), processing \(haveProcessID ? "PRESENT" : "MISSING").",
            extra: [
                "count": String(ids.count),
                "refreshIdentifier": BackgroundProbeIDs.refresh,
                "processIdentifier": BackgroundProbeIDs.process,
                "refreshPermitted": haveRefreshID ? "true" : "false",
                "processPermitted": haveProcessID ? "true" : "false"
            ]
        ))

        // ------------------------------------------------------------------
        // 2. The user's switch — the highest-leverage toggle on the device
        // ------------------------------------------------------------------
        let refreshStatus: ProbeStatus
        switch ui.backgroundRefreshRaw {
        case 2: refreshStatus = .ok
        case 1: refreshStatus = .denied
        case 0: refreshStatus = .denied      // restricted — same practical effect
        default: refreshStatus = .error
        }
        items.append(ProbeItem(
            "background.refreshStatus",
            "Background App Refresh",
            refreshStatus,
            value: ui.backgroundRefresh.uppercased(),
            detail: {
                switch ui.backgroundRefreshRaw {
                case 2:
                    return "AVAILABLE. The system is permitted to relaunch this app in the background. This is the precondition for BGTaskScheduler, for HealthKit background delivery, for silent push AND — the part that surprises people — for every CoreLocation background event including significant-location-change and region monitoring. Settings › General › Background App Refresh."
                case 1:
                    return "DENIED — the user has turned Background App Refresh OFF for this app (or globally). Read this as the collector being dead, not degraded. With this off, iOS relaunches the app for NO background event of any kind: no BGTask, no silent push, no HealthKit observer, and no location event — Apple documents that significant-change and region monitoring are suppressed too. Nothing in CoreLocation reports this; only this API does. Fix in Settings › General › Background App Refresh."
                case 0:
                    return "RESTRICTED — background refresh is blocked by a policy the user cannot change from the app: Low Power Mode restriction, a Screen Time / MDM restriction, or parental controls. Practically identical in effect to denied. Note Low Power Mode does NOT normally report as restricted; it silently reduces the frequency instead, which is why the low-power item below is reported separately."
                default:
                    return "backgroundRefreshStatus returned an unmapped raw value \(ui.backgroundRefreshRaw). Treat as unknown."
                }
            }(),
            extra: [
                "raw": String(ui.backgroundRefreshRaw),
                "affectsBGTaskScheduler": "true",
                "affectsCoreLocationRelaunch": "true",
                "affectsSilentPush": "true",
                "affectsHealthKitBackgroundDelivery": "true"
            ]
        ))

        items.append(ProbeItem(
            "background.lowPowerMode",
            "Low Power Mode",
            ui.isLowPowerMode ? .partial : .ok,
            value: ui.isLowPowerMode ? "ON" : "off",
            detail: ui.isLowPowerMode
                ? "Low Power Mode is ON. It does not flip backgroundRefreshStatus to restricted — it silently throttles background activity: BGTask opportunities become rare or stop, background fetch is suspended, and background location updates are reduced. A collector that sees a long ledger gap should check whether Low Power Mode explains it before blaming the API."
                : "Off. Background scheduling is not being throttled by the battery-saving policy at probe time. This flag is worth writing into every ledger line — it is the most common innocent explanation for a suspicious gap.",
            extra: [
                "thermalState": BackgroundProbeUI.thermalName(ui.thermalStateRaw),
                "batteryLevel": ui.batteryLevel < 0 ? "unavailable" : String(format: "%.0f%%", ui.batteryLevel * 100),
                "batteryState": BackgroundProbeUI.batteryStateName(ui.batteryStateRaw)
            ]
        ))

        // ------------------------------------------------------------------
        // 3. Where this process came from
        // ------------------------------------------------------------------
        let procAge = procStart.map { Date().timeIntervalSince($0) }
        items.append(ProbeItem(
            "background.appState",
            "Application state at probe time",
            .ok,
            value: ui.applicationState,
            detail: "Read from UIApplication.applicationState the moment this probe ran. Be honest about what this can and cannot prove: the probe is triggered by a button tap, so \"active\" is the only value it will ever realistically show, and a foreground reading is NOT evidence about background launches. The state that matters is the state at the instant the PROCESS started, and that is captured only by BackgroundProbeScheduler.installAtLaunch() — see the launch-origin item below. The per-launch state history lives in the ledger."
                + (procAge == nil
                    ? " NOTE: sysctl KERN_PROC_PID returned no process start time on this OS (processStart reads \"unknown\" below while bootTime resolves). Apple has been progressively narrowing sysctl process introspection; that column is simply lost, and nothing else in this section depends on it."
                    : " This process has been alive " + BackgroundProbeFmt.dur(procAge ?? 0) + "."),
            extra: [
                "raw": String(ui.applicationStateRaw),
                "protectedDataAvailable": ui.protectedDataAvailable ? "true" : "false",
                "processStart": ProbeEnv.stamp(procStart) ?? "unknown",
                "processAgeSec": procAge.map { String(format: "%.1f", $0) } ?? "unknown",
                "bootTime": ProbeEnv.stamp(bootTime) ?? "unknown",
                "systemUptimeSec": String(Int(ProcessInfo.processInfo.systemUptime))
            ]
        ))

        let hookRan = BackgroundProbeScheduler.didInstall
        let recordedState = BackgroundProbeScheduler.recordedLaunchState
        items.append(ProbeItem(
            "background.launchOrigin",
            "Launched into background, or by the user?",
            hookRan ? .ok : .notDetermined,
            value: hookRan
                ? "process started in state: \(recordedState ?? "unknown")"
                : "NOT MEASURED — launch hook never ran",
            detail: hookRan
                ? "BackgroundProbeScheduler.installAtLaunch() ran at \(ProbeEnv.stamp(BackgroundProbeScheduler.installTime) ?? "?") and captured the application state at process start. \"background\" means iOS started this process with no user involvement — the thing the whole collector depends on. Launch option keys seen: \(BackgroundProbeScheduler.recordedLaunchOptionKeys.isEmpty ? "none" : BackgroundProbeScheduler.recordedLaunchOptionKeys.joined(separator: ", ")). UIApplication.LaunchOptionsKey.location appearing there is Apple's documented proof that CoreLocation, specifically, did the waking."
                : "Not answerable on this build. ProbeApp.swift never calls BackgroundProbeScheduler.installAtLaunch(), so nothing observed the application state at process start, and by the time any probe runs that information is irrecoverable. This is a one-line fix in ProbeApp.swift:\n\n    init() { BackgroundProbeScheduler.installAtLaunch(launchOptions: nil) }\n\nUntil then the launch-origin question is answered indirectly, and weakly, by the state column of the ledger.",
            extra: [
                "installHookRan": hookRan ? "true" : "false",
                "recordedLaunchState": recordedState ?? "n/a",
                "launchOptionKeys": BackgroundProbeScheduler.recordedLaunchOptionKeys.joined(separator: ", ")
            ]
        ))

        // ------------------------------------------------------------------
        // 4. The 30-second budget
        // ------------------------------------------------------------------
        let sentinel = BackgroundProbeFmt.isForegroundSentinel(ui.backgroundTimeRemaining)
        items.append(ProbeItem(
            "background.timeRemaining",
            "backgroundTimeRemaining + beginBackgroundTask budget",
            ui.gathered ? .ok : .error,
            value: sentinel
                ? "foreground sentinel (\(BackgroundProbeFmt.raw(ui.backgroundTimeRemaining)))"
                : BackgroundProbeFmt.dur(ui.backgroundTimeRemaining),
            detail: (sentinel
                ? "In the foreground UIKit returns Double.greatestFiniteMagnitude (≈1.8e308) for backgroundTimeRemaining, meaning \"unlimited, the question does not apply\". That is exactly what was observed, and it is the CORRECT result, not a failure. A real background task assertion was taken with beginBackgroundTask(withName:) and the value was re-read: \(BackgroundProbeFmt.raw(ui.backgroundTimeRemainingAfterBegin)) — it does not move in the foreground either, because the budget only starts counting when the app actually leaves the screen. The assertion was ended immediately, so no background time was consumed."
                : "backgroundTimeRemaining returned a finite value — the app is genuinely running on a background assertion right now, and this is the real remaining budget.")
                + "\n\nWHAT THE BUDGET ACTUALLY IS: beginBackgroundTask(withName:expirationHandler:) buys roughly 30 seconds of wall-clock execution after the app leaves the foreground (it was ~180 s before iOS 13 and is not contractual — treat 30 s as the planning number and never rely on a specific figure). The expiration handler fires shortly BEFORE the budget runs out; if endBackgroundTask has not been called by the time it does, iOS kills the process outright and that kill looks like a crash in the logs. It is a grace period for finishing work already in flight, not a mechanism for doing new work, and it cannot be renewed by chaining a second assertion. For a telemetry collector the practical rule is: everything that must happen during a background wake has to fit in a single, bounded, interruptible unit of work — write to the local SQLite first, sync opportunistically second, and treat the sync as cancellable at any instant.",
            extra: [
                "raw": BackgroundProbeFmt.raw(ui.backgroundTimeRemaining),
                "rawAfterBeginBackgroundTask": BackgroundProbeFmt.raw(ui.backgroundTimeRemainingAfterBegin),
                "isForegroundSentinel": sentinel ? "true" : "false",
                "beginBackgroundTaskGranted": ui.beginBackgroundTaskGranted ? "true" : "false",
                "beginBackgroundTaskIdentifier": String(ui.beginBackgroundTaskIdentifier),
                "plannedBudgetSeconds": "30",
                "bgAppRefreshBudgetSeconds": "30",
                "bgProcessingBudgetSeconds": "minutes (uncontracted; typically 1-10)"
            ]
        ))

        // ------------------------------------------------------------------
        // 5. Registration — reported, deliberately not performed
        // ------------------------------------------------------------------
        let regResults = BackgroundProbeScheduler.registrationResults
        var regParts: [String] = []
        for (identifier, ok) in regResults {
            let shortName = identifier.components(separatedBy: ".").last ?? identifier
            regParts.append(shortName + "=" + (ok ? "YES" : "NO"))
        }
        regParts.sort()
        let regSummary = regParts.joined(separator: ", ")
        let regStatus: ProbeStatus = hookRan
            ? ((regResults[BackgroundProbeIDs.refresh] == true && regResults[BackgroundProbeIDs.process] == true) ? .ok : .partial)
            : .notDetermined
        items.append(ProbeItem(
            "background.register.state",
            "BGTaskScheduler launch handlers",
            regStatus,
            value: hookRan
                ? regSummary
                : "NOT REGISTERED — no handler exists for either identifier",
            detail: hookRan
                ? "installAtLaunch() ran and registered both identifiers. register() returns NO — not an exception — when the identifier is missing from BGTaskSchedulerPermittedIdentifiers, so these return values are an independent measurement of the shipped plist, taken at launch, before anything could have modified it."
                : "No launch handler is registered for either identifier in this build, so even a granted background opportunity has nothing to run. Submissions and the pending queue below are still fully measurable — the scheduler accepts requests independently of whether a handler exists — but no BGTask can EXECUTE until ProbeApp.init() calls BackgroundProbeScheduler.installAtLaunch().",
            extra: [
                "hookRan": hookRan ? "true" : "false",
                "refreshRegistered": (regResults[BackgroundProbeIDs.refresh].map { $0 ? "true" : "false" }) ?? "n/a",
                "processRegistered": (regResults[BackgroundProbeIDs.process].map { $0 ? "true" : "false" }) ?? "n/a"
            ]
        ))

        items.append(ProbeItem(
            "background.register.constraint",
            "Why this probe does not call register()",
            .partial,
            value: "registration is launch-time-only, by API contract",
            detail: "This is the single most important operational constraint in the BackgroundTasks framework and it is worth stating precisely, because getting it wrong does not produce an error — it produces a crash.\n\nApple's BGTaskScheduler.h: \"You must register launch handlers before your application finishes launching. Attempting to register a handler after launch or multiple handlers for the same identifier is an error.\" And: \"Register each task identifier only once. The system kills the app on the second registration of the same task identifier.\"\n\nBoth failures raise NSInternalInconsistencyException from BGTaskScheduler.m:185 — \"All launch handlers must be registered before application finishes launching\". That is an Objective-C exception. Swift cannot catch it. There is no do/try/catch, no guard, and no defensive check that makes it survivable, so a probe that called register() from a button tap would take all eleven sections of this report down with it every single run. It is therefore deliberately not called here.\n\nTHREE CONSEQUENCES FOR THE COLLECTOR:\n1. Registration belongs in ProbeApp.init() or application(_:didFinishLaunchingWithOptions:), never in onAppear, never in a view model, never lazily on first use, and never from a third-party SDK's delayed initialiser — that last one is the single most common cause of this crash in the wild.\n2. Registration must happen on EVERY launch, including the background launches. The registry does not persist across process death; an app that registers only when the user opens it will be woken and will have no handler to run.\n3. Every identifier listed in BGTaskSchedulerPermittedIdentifiers needs a handler. An identifier with no handler is a wake the system may grant and the app cannot use.\n\nThe full, idempotent, lock-guarded implementation is present in this file as BackgroundProbeScheduler.installAtLaunch(launchOptions:) — including handlers that append to the launch ledger and immediately resubmit, so the ledger becomes a self-sustaining record of real wakeups. It needs one line in ProbeApp.swift to become live.",
            extra: [
                "exceptionSite": "BGTaskScheduler.m:185",
                "exceptionName": "NSInternalInconsistencyException",
                "catchableFromSwift": "false",
                "safeCallSite": "ProbeApp.init() / application(_:didFinishLaunchingWithOptions:)",
                "hookSymbol": "BackgroundProbeScheduler.installAtLaunch(launchOptions:)"
            ]
        ))

        // Runtime class sweep — verifies the SDK/OS surface without hard-coding
        // a compile-time dependency on a symbol whose spelling can't be checked.
        var present: [String] = []
        var absent: [String] = []
        var sweepExtra: [String: String] = [:]
        for (name, note) in BackgroundProbeTasks.classSweep {
            let ok = (NSClassFromString(name) != nil)
            sweepExtra[name] = ok ? "present" : "absent"
            if ok { present.append(name) } else { absent.append(name) }
            _ = note
        }
        items.append(ProbeItem(
            "background.classes",
            "BackgroundTasks runtime class sweep",
            present.isEmpty ? .unavailable : (absent.isEmpty ? .ok : .partial),
            value: "\(present.count)/\(BackgroundProbeTasks.classSweep.count) classes resolve",
            detail: "NSClassFromString probe of every BackgroundTasks class this project might use, run against the OS the app is actually on. This is how the newer task types are checked without taking a compile-time dependency on a symbol name that cannot be verified from the build machine.\n\nPresent: \(present.joined(separator: ", ")).\nAbsent: \(absent.isEmpty ? "none" : absent.joined(separator: ", ")).\n\nBGContinuedProcessingTaskRequest is the iOS 26 addition — user-initiated background work with a live progress UI, intended for exports and uploads the user explicitly started. It is NOT a telemetry mechanism: it requires user initiation and shows system UI, so it cannot be used for unattended collection. It is swept here only to establish what this OS build actually ships. BGHealthResearchTaskRequest (iOS 17) needs an Apple-granted research entitlement and is out of reach at any self-signing tier.",
            extra: sweepExtra
        ))

        // ------------------------------------------------------------------
        // 6. The pending queue BEFORE we touch it — what survived since last run
        // ------------------------------------------------------------------
        let defaults = UserDefaults.standard
        let lastSubmitKey = BackgroundProbeIDs.defaultsPrefix + "lastSubmitISO"
        let lastRunKey = BackgroundProbeIDs.defaultsPrefix + "lastRunISO"
        let submitCountKey = BackgroundProbeIDs.defaultsPrefix + "submitCount"
        let previousSubmitISO = defaults.string(forKey: lastSubmitKey)
        let previousRunISO = defaults.string(forKey: lastRunKey)
        let previousSubmitCount = defaults.integer(forKey: submitCountKey)

        let before = await BackgroundProbeTasks.pending()

        if let before {
            let ourRefresh = before.first { $0.identifier == BackgroundProbeIDs.refresh }
            let ourProcess = before.first { $0.identifier == BackgroundProbeIDs.process }
            items.append(ProbeItem(
                "background.pending.before",
                "Pending task queue (before this run)",
                before.isEmpty ? .empty : .ok,
                value: before.isEmpty ? "0 pending" : "\(before.count) pending",
                detail: before.isEmpty
                    ? "The scheduler holds no pending requests for this app at the start of this run."
                        + (previousSubmitISO == nil
                            ? " No previous submission is on record, so this is expected on a first run."
                            : " A submission WAS made on \(previousSubmitISO ?? "?") and nothing is queued now — see the survival item below.")
                    : "Queued at the start of this run, before this probe submitted anything:\n" + before.map { "• " + $0.describe }.joined(separator: "\n")
                        + "\n\nPending requests are persisted by the system across app termination and across reboot, which is why this read is meaningful at all.",
                extra: [
                    "count": String(before.count),
                    "identifiers": before.map { $0.identifier }.joined(separator: ", "),
                    "ourRefreshQueued": ourRefresh != nil ? "true" : "false",
                    "ourProcessQueued": ourProcess != nil ? "true" : "false",
                    "previousSubmitISO": previousSubmitISO ?? "none",
                    "previousRunISO": previousRunISO ?? "none",
                    "previousSubmitCount": String(previousSubmitCount)
                ]
            ))

            // Cross-run survival inference — carefully hedged.
            if let previousSubmitISO {
                let refreshGone = (ourRefresh == nil)
                let processGone = (ourProcess == nil)
                let status: ProbeStatus = (refreshGone || processGone) ? .partial : .ok

                var survivalDetail = "Last submitted " + previousSubmitISO
                if let submittedAt = ProbeEnv.iso.date(from: previousSubmitISO),
                   let ageText = ProbeEnv.age(submittedAt) {
                    survivalDetail += " (" + ageText + ")"
                }
                survivalDetail += ". "
                if refreshGone || processGone {
                    survivalDetail += "At least one previously submitted request is NO LONGER in the queue. READ THIS CAREFULLY, because it is easy to over-claim: a request leaves the queue when the system launches the app for it, but it can also be dropped for other reasons, and — critically — with no launch handler registered in this build (see above) the system can consume the request without any of our code running. So a vanished request is SUGGESTIVE of a background wake and is NOT proof of one. The signal only becomes clean once installAtLaunch() is wired in, at which point a real wake writes a bgtask.* line into the ledger and the two pieces of evidence corroborate each other."
                } else {
                    survivalDetail += "Both requests are still queued and have not been consumed. Either the earliest-begin date has not passed, or the system has not yet judged this app worth waking. A refresh request that stays queued for days is itself the finding: it means iOS has scored this app as not worth the energy."
                }

                items.append(ProbeItem(
                    "background.pending.survival",
                    "Did the previously submitted requests survive?",
                    status,
                    value: "refresh \(refreshGone ? "GONE" : "still queued"), processing \(processGone ? "GONE" : "still queued")",
                    detail: survivalDetail,
                    extra: [
                        "previousSubmitISO": previousSubmitISO,
                        "refreshSurvived": refreshGone ? "false" : "true",
                        "processSurvived": processGone ? "false" : "true",
                        "inferenceIsProof": "false",
                        "handlerRegistered": hookRan ? "true" : "false"
                    ]
                ))
            }
        } else {
            items.append(ProbeItem(
                "background.pending.before",
                "Pending task queue (before this run)",
                .error,
                value: "getPendingTaskRequests did not return within 10 s",
                detail: "The completion handler never fired inside the timeout. On a real device this call is normally instant; a hang here points at the scheduler daemon (dasd) being wedged, which is itself worth knowing about."
            ))
        }

        // ------------------------------------------------------------------
        // 7. Real submissions
        // ------------------------------------------------------------------
        let refreshRequest = BGAppRefreshTaskRequest(identifier: BackgroundProbeIDs.refresh)
        refreshRequest.earliestBeginDate = Date(timeIntervalSinceNow: 60)
        let refreshResult = BackgroundProbeTasks.submit(refreshRequest)

        items.append(ProbeItem(
            "background.submit.refresh",
            "Submit BGAppRefreshTaskRequest",
            refreshResult.submitted ? .ok : (refreshResult.errorCode == 1 && ProbeEnv.isSimulator ? .unavailable : .denied),
            value: refreshResult.submitted
                ? "ACCEPTED — earliest begin in 60 s"
                : "REJECTED — \(refreshResult.domainText) code \(refreshResult.codeText)",
            detail: refreshResult.submitted
                ? "The scheduler accepted a real BGAppRefreshTaskRequest for \(BackgroundProbeIDs.refresh) with earliestBeginDate set 60 seconds out. Acceptance proves three things at once: \"fetch\" is in UIBackgroundModes, the identifier is in BGTaskSchedulerPermittedIdentifiers, and Background App Refresh is enabled — those are the only three documented rejection causes. Acceptance proves NOTHING about whether the task will ever run. earliestBeginDate is a floor, not a schedule: iOS decides when, based on how often the user opens the app, battery, thermal state and network. Days of latency are normal; never is possible. A refresh task grants roughly 30 seconds of execution when it does run."
                : "Submission threw.\nError: \(refreshResult.errorText ?? "?")\nDomain: \(refreshResult.domainText)  Code: \(refreshResult.codeText)\n\n\(refreshResult.interpretation ?? "")",
            extra: [
                "identifier": BackgroundProbeIDs.refresh,
                "earliestBeginDate": ProbeEnv.stamp(refreshRequest.earliestBeginDate) ?? "nil",
                "submitted": refreshResult.submitted ? "true" : "false",
                "errorDomain": refreshResult.errorDomain ?? "",
                "errorCode": refreshResult.errorCode == nil ? "" : refreshResult.codeText,
                "maxPendingRefreshRequests": String(BackgroundProbeIDs.maxPendingRefresh),
                "executionBudgetSeconds": "30"
            ]
        ))

        let processRequest = BGProcessingTaskRequest(identifier: BackgroundProbeIDs.process)
        processRequest.requiresNetworkConnectivity = true
        processRequest.requiresExternalPower = false
        processRequest.earliestBeginDate = Date(timeIntervalSinceNow: 60)
        let processResult = BackgroundProbeTasks.submit(processRequest)

        items.append(ProbeItem(
            "background.submit.processing",
            "Submit BGProcessingTaskRequest",
            processResult.submitted ? .ok : (processResult.errorCode == 1 && ProbeEnv.isSimulator ? .unavailable : .denied),
            value: processResult.submitted
                ? "ACCEPTED — network required, external power NOT required"
                : "REJECTED — \(processResult.domainText) code \(processResult.codeText)",
            detail: processResult.submitted
                ? "The scheduler accepted a real BGProcessingTaskRequest for \(BackgroundProbeIDs.process) with requiresNetworkConnectivity = true and requiresExternalPower = false. This is the slot a telemetry collector wants for bulk sync: it grants minutes rather than seconds. The tradeoff is scheduling: requiresExternalPower = true makes the task far more likely to be granted but confines it to charging-and-idle, which in practice means overnight; false makes it eligible any time and correspondingly rarer. Deliberately set to false here so the ledger measures the HARDER case — if wakes happen on battery, they will certainly happen on charge. The queue ceiling is 10 pending processing requests versus 1 refresh."
                : "Submission threw.\nError: \(processResult.errorText ?? "?")\nDomain: \(processResult.domainText)  Code: \(processResult.codeText)\n\n\(processResult.interpretation ?? "")",
            extra: [
                "identifier": BackgroundProbeIDs.process,
                "requiresNetworkConnectivity": "true",
                "requiresExternalPower": "false",
                "earliestBeginDate": ProbeEnv.stamp(processRequest.earliestBeginDate) ?? "nil",
                "submitted": processResult.submitted ? "true" : "false",
                "errorDomain": processResult.errorDomain ?? "",
                "errorCode": processResult.errorCode == nil ? "" : processResult.codeText,
                "maxPendingProcessingRequests": String(BackgroundProbeIDs.maxPendingProcessing)
            ]
        ))

        if refreshResult.submitted || processResult.submitted {
            defaults.set(ProbeEnv.iso.string(from: Date()), forKey: lastSubmitKey)
            defaults.set(previousSubmitCount + 1, forKey: submitCountKey)
        }
        defaults.set(ProbeEnv.iso.string(from: Date()), forKey: lastRunKey)

        // ------------------------------------------------------------------
        // 8. The pending queue AFTER
        // ------------------------------------------------------------------
        let after = await BackgroundProbeTasks.pending()
        if let after {
            items.append(ProbeItem(
                "background.pending.after",
                "Pending task queue (after submission)",
                after.isEmpty ? .empty : .ok,
                value: "\(after.count) pending",
                detail: after.isEmpty
                    ? "The queue is EMPTY immediately after two submissions that reported success. That combination should not happen and is worth chasing: either the submissions did not really land, or the system discarded them instantly."
                    : "Read back from the scheduler after submitting. These are copies — mutating them does nothing; to change a pending request you resubmit it under the same identifier, which replaces the old one:\n"
                        + after.map { "• " + $0.describe }.joined(separator: "\n")
                        + "\n\nThese requests are LEFT IN PLACE on purpose. Cancelling them would destroy the cross-run experiment: the next run's \"before\" read is what tells us whether the system consumed them in the interim.",
                extra: [
                    "count": String(after.count),
                    "identifiers": after.map { $0.identifier }.joined(separator: ", "),
                    "queueCeilingRefresh": String(BackgroundProbeIDs.maxPendingRefresh),
                    "queueCeilingProcessing": String(BackgroundProbeIDs.maxPendingProcessing),
                    "leftInPlace": "true"
                ]
            ))
        } else {
            items.append(ProbeItem(
                "background.pending.after",
                "Pending task queue (after submission)",
                .error,
                value: "getPendingTaskRequests did not return within 10 s",
                detail: "The read-back timed out. The submissions above may still have landed."
            ))
        }

        // Record the scheduler telemetry as a second ledger line (reason
        // "probe.tasks") so it never double-counts as a launch.
        BackgroundProbeLedger.appendLine(
            reason: "probe.tasks",
            extra: [
                "pendingBefore": before.map { String($0.count) } ?? "unknown",
                "pendingAfter": after.map { String($0.count) } ?? "unknown",
                "submitRefresh": refreshResult.submitted ? "1" : "0",
                "submitProcess": processResult.submitted ? "1" : "0",
                "refreshErrorCode": refreshResult.errorCode == nil ? "" : refreshResult.codeText,
                "processErrorCode": processResult.errorCode == nil ? "" : processResult.codeText,
                "bgRefreshStatus": ui.backgroundRefresh
            ]
        )

        // ------------------------------------------------------------------
        // 9. The launch ledger — the only thing here that beats documentation
        // ------------------------------------------------------------------
        let ledgerPath = BackgroundProbeLedger.url?.path ?? "unavailable"
        items.append(ProbeItem(
            "background.ledger.append",
            "Launch ledger write",
            appendError == nil ? .ok : .error,
            value: appendError == nil ? "appended" : "FAILED",
            detail: appendError == nil
                ? "A timestamped NDJSON record was appended to \(BackgroundProbeLedger.fileName) in Documents before any framework call in this section, so the launch is recorded even if a later call stalls and ProbeRunner discards the whole section on its 180 s timeout. Append-only via FileHandle.seekToEnd — never read-modify-write, because a crash mid-rewrite would destroy the entire history, and the history is the one artifact in this project that cannot be regenerated. UIFileSharingEnabled is set, so the file is pullable off the phone through Files › On My iPhone › Probe with no cable and no Mac."
                : "Ledger append failed: \(appendError ?? "?"). Without it the wakeup question stays unanswerable, so this is a higher-priority failure than it looks.",
            extra: [
                "path": ledgerPath,
                "format": "NDJSON, one JSON object per line",
                "fields": "ts, reason, bootKey, procStart, uptimeSec, sysVersion, build, lowPower, thermal, state, bgRefresh, battery, batteryState, protectedData"
            ]
        ))

        let st = BackgroundProbeLedger.stats()

        let reasonPairs: [String] = st.byReason.sorted { $0.key < $1.key }.map { pair in
            pair.key + "=" + String(pair.value)
        }
        let statePairs: [String] = st.byState.sorted { $0.key < $1.key }.map { pair in
            pair.key + "=" + String(pair.value)
        }

        var totalDetail = "Counted from " + ProbeEnv.int(st.parsedLines) + " parsed record(s) in "
        totalDetail += BackgroundProbeFmt.bytes(st.fileBytes)
        if st.truncatedRead { totalDetail += " (only the trailing 4 MB was read)" }
        totalDetail += ". Only records with reason \"launch\", \"probe\" or a \"bgtask.*\" prefix count as launches; the per-run scheduler telemetry line is excluded so it cannot inflate the count."
        if st.malformedLines > 0 {
            totalDetail += " " + String(st.malformedLines) + " line(s) failed to parse and were skipped."
        }
        totalDetail += "\n\nBy reason: " + (reasonPairs.isEmpty ? "none" : reasonPairs.joined(separator: ", "))
        totalDetail += "\nBy application state at record time: "
        totalDetail += statePairs.isEmpty ? "none recorded" : statePairs.joined(separator: ", ")
        totalDetail += "\n\nThe number that matters is the count of records whose state is \"background\": "
        totalDetail += ProbeEnv.int(st.backgroundLaunches)
        totalDetail += ". That is the count of times iOS ran this app's code with nobody looking. Every other figure in this section is a capability claim; that one is the outcome."

        items.append(ProbeItem(
            "background.ledger.total",
            "Launches recorded",
            st.launchCount == 0 ? .empty : .ok,
            value: ProbeEnv.int(st.launchCount),
            detail: totalDetail,
            extra: [
                "launchCount": String(st.launchCount),
                "parsedLines": String(st.parsedLines),
                "malformedLines": String(st.malformedLines),
                "backgroundStateRecords": String(st.backgroundLaunches),
                "fileBytes": String(st.fileBytes),
                "truncatedRead": st.truncatedRead ? "true" : "false"
            ]
        ))

        var windowDays: Double = 0
        if let f = st.first {
            windowDays = Date().timeIntervalSince(f) / 86_400
        }
        var firstDetail: String
        if st.first == nil {
            firstDetail = "The ledger has no launch record older than this run — this is the first data point. Come back in a week; that is when this section starts producing findings no documentation can give."
        } else {
            firstDetail = "Observation window opened " + (ProbeEnv.age(st.first) ?? "?") + "."
            if st.launchCount > 1 {
                let meanText: String = st.meanGap == nil ? "?" : BackgroundProbeFmt.dur(st.meanGap ?? 0)
                let shortText: String = st.shortestGap == nil ? "?" : BackgroundProbeFmt.dur(st.shortestGap ?? 0)
                let denom: Double = windowDays > 0.0001 ? windowDays : 0.0001
                let rate: Double = Double(st.launchCount) / denom
                firstDetail += " Across that window: " + ProbeEnv.int(st.launchCount) + " launches, "
                firstDetail += "a mean gap of " + meanText + " and a shortest gap of " + shortText
                firstDetail += String(format: " — an effective rate of %.2f launches/day.", rate)
            }
        }

        items.append(ProbeItem(
            "background.ledger.first",
            "First launch recorded",
            st.first == nil ? .empty : .ok,
            value: ProbeEnv.stamp(st.first) ?? "none",
            detail: firstDetail,
            extra: [
                "firstISO": ProbeEnv.stamp(st.first) ?? "",
                "lastISO": ProbeEnv.stamp(st.last) ?? "",
                "windowDays": String(format: "%.3f", windowDays),
                "meanGapSec": st.meanGap == nil ? "" : String(format: "%.0f", st.meanGap ?? 0),
                "shortestGapSec": st.shortestGap == nil ? "" : String(format: "%.0f", st.shortestGap ?? 0)
            ]
        ))

        items.append(ProbeItem(
            "background.ledger.gapLast",
            "Most recent gap between launches",
            st.lastGap == nil ? .empty : .ok,
            value: st.lastGap.map { BackgroundProbeFmt.dur($0) } ?? "n/a (fewer than 2 launches)",
            detail: st.lastGap == nil
                ? "At least two launch records are needed before a gap exists."
                : "Elapsed between the two most recent launch records. Short gaps mean the user opened the app; only long gaps closed by a record whose state is \"background\" are evidence of an OS-initiated wake.",
            extra: ["lastGapSec": st.lastGap.map { String(format: "%.0f", $0) } ?? ""]
        ))

        items.append(ProbeItem(
            "background.ledger.gapLongest",
            "Longest gap between launches",
            st.longestGap == nil ? .empty : .ok,
            value: st.longestGap.map { BackgroundProbeFmt.dur($0) } ?? "n/a (fewer than 2 launches)",
            detail: st.longestGap == nil
                ? "Needs at least two launch records."
                : "The worst observed silence, ending \(ProbeEnv.stamp(st.longestGapEndedAt) ?? "?"). This is the single most useful number for sizing the collector: it is the empirical upper bound on how long data must survive on-device before a sync opportunity appears, which sets the local SQLite retention floor and the sync batch size. Design for the longest gap, not the mean — the mean is dominated by the user opening the app, which is exactly the case the collector does not need help with.",
            extra: [
                "longestGapSec": st.longestGap.map { String(format: "%.0f", $0) } ?? "",
                "longestGapEndedISO": ProbeEnv.stamp(st.longestGapEndedAt) ?? ""
            ]
        ))

        items.append(ProbeItem(
            "background.ledger.boots",
            "Distinct device boots observed",
            st.distinctBoots == 0 ? .empty : .ok,
            value: ProbeEnv.int(st.distinctBoots),
            detail: "Every ledger line carries a boot key derived from sysctl KERN_BOOTTIME, rounded to the nearest minute — iOS recomputes boot time from the monotonic clock and it drifts by a second or two between reads, so an unrounded value would fabricate a phantom reboot on almost every run. Current boot: \(ProbeEnv.stamp(bootTime) ?? "unknown") (\(ProbeEnv.age(bootTime) ?? "?")); uptime \(BackgroundProbeFmt.dur(ProcessInfo.processInfo.systemUptime)).\n\nWhy this column earns its place: a reboot CLEARS the force-quit suppression flag. Apple DTS: \"the user must launch the app explicitly or reboot the device before the app can be launched automatically into the background by the system.\" So a ledger record whose boot key is new AND whose state is \"background\" — with no user launch in between — is direct proof that a wake source survived a reboot unaided. No documentation can establish that for this specific phone.",
            extra: [
                "distinctBoots": String(st.distinctBoots),
                "currentBootISO": ProbeEnv.stamp(bootTime) ?? "",
                "currentBootKey": BackgroundProbeSys.bootKey(bootTime),
                "uptimeSec": String(Int(ProcessInfo.processInfo.systemUptime)),
                "processStartISO": ProbeEnv.stamp(procStart) ?? ""
            ]
        ))

        return section(BackgroundProbeSummary.build(ui: ui,
                                                    plist: plist,
                                                    hookRan: hookRan,
                                                    refresh: refreshResult,
                                                    process: processResult,
                                                    pendingAfter: after?.count,
                                                    stats: st),
                       items)
    }
}

// MARK: - Section summary

enum BackgroundProbeSummary {

    static func build(ui: BackgroundProbeUISnapshot,
                      plist: BackgroundProbePlistView,
                      hookRan: Bool,
                      refresh: BackgroundProbeSubmitResult,
                      process: BackgroundProbeSubmitResult,
                      pendingAfter: Int?,
                      stats: BackgroundProbeLedgerStats) -> String {

        var s = ""

        let modeText: String = plist.loaderModes.isEmpty
            ? "none"
            : plist.loaderModes.joined(separator: "/")
        let pendingText: String = pendingAfter == nil ? "?" : String(pendingAfter ?? 0)
        let longestText: String = stats.longestGap == nil
            ? "n/a"
            : BackgroundProbeFmt.dur(stats.longestGap ?? 0)

        // --- What this run measured -------------------------------------
        s += "Background App Refresh is " + ui.backgroundRefresh.uppercased() + "; "
        s += "UIBackgroundModes = " + modeText + "; "
        s += "BGAppRefreshTaskRequest " + (refresh.submitted ? "ACCEPTED" : "REJECTED(code " + refresh.codeText + ")") + ", "
        s += "BGProcessingTaskRequest " + (process.submitted ? "ACCEPTED" : "REJECTED(code " + process.codeText + ")") + "; "
        s += pendingText + " request(s) left queued on purpose. "
        s += "Launch ledger: " + ProbeEnv.int(stats.launchCount) + " launch(es), "
        s += ProbeEnv.int(stats.backgroundLaunches) + " of them recorded in the background state, "
        s += "longest gap " + longestText + ". "
        if !hookRan {
            s += "NO BGTaskScheduler launch handler is registered in this build, so a granted wake has nothing to run — one line in ProbeApp.init() calling BackgroundProbeScheduler.installAtLaunch() fixes it. "
        }
        s += "\n\n"

        // --- The hierarchy ----------------------------------------------
        s += "THE WAKE-SOURCE HIERARCHY FOR A SIDELOADED PERSONAL APP, RANKED BY RELIABILITY. "
        s += "Claims are tiered by evidence, because a flat confident list containing one unsourced "
        s += "claim is worse than a hedged one.\n\n"

        s += "TIER A — DOCUMENTED BY APPLE, LOAD-BEARING. Read #1 as categorically "
        s += "different from #2-#6, not merely better: REGION MONITORING IS THE ONLY SOURCE ON "
        s += "THIS ENTIRE LIST THAT SURVIVES A USER FORCE-QUIT. Every other entry below, "
        s += "including significant-location-change and visit monitoring, is conditional on the "
        s += "app never having been swiped out of the app switcher.\n"
        s += "1. REGION MONITORING (CLLocationManager.startMonitoring(for:), and its iOS 17 successor "
        s += "CLMonitor with persistent conditions). The strongest wake source that exists on iOS, and "
        s += "the ONLY one that reliably relaunches an app the user force-quit. Apple DTS is explicit: "
        s += "\"In most cases, the system does not relaunch apps after they are force quit by the user. "
        s += "One exception is location apps, which in iOS 8 and later are relaunched after being force "
        s += "quit\" — and, narrowing it further, \"For location apps, this case is Region Monitoring. "
        s += "Only if your app is a Region Monitoring app can you expect it to be relaunched "
        s += "consistently after the user force quits it. None of the other location services can be "
        s += "relied on to have your app re-launched after a force quit.\" Regions persist across "
        s += "termination and across reboot; the system, not the app, holds them. Hard cap: 20 regions "
        s += "per app, shared across every CLLocationManager instance, so a place-based collector has "
        s += "to swap geofences dynamically. Needs Always authorization.\n"
        s += "2. SIGNIFICANT-LOCATION-CHANGE (startMonitoringSignificantLocationChanges). Documented to "
        s += "relaunch a TERMINATED app — \"the system automatically relaunches the app into the "
        s += "background if a new event arrives\", flagged by UIApplication.LaunchOptionsKey.location. "
        s += "Cheap (cell-tower granularity, ~500 m / 5 min). But note the distinction that matters: "
        s += "system-initiated termination is not the same as user force-quit, and SLC is NOT reliable "
        s += "across the latter. Needs Always authorization; requires no UIBackgroundModes entry.\n"
        s += "3. VISIT MONITORING (startMonitoringVisits). \"If your app is terminated while this "
        s += "service is active, the system relaunches your app when new visit events are ready.\" "
        s += "Semantically the richest location signal (arrive/depart with dwell times) and the "
        s += "cheapest in power, because it rides machinery iOS already runs for its own purposes. "
        s += "Same force-quit caveat as SLC. Zero backfill — it only ever reports events that occur "
        s += "while registered, so a gap is permanent.\n"
        s += "4. HEALTHKIT BACKGROUND DELIVERY (HKHealthStore.enableBackgroundDelivery + "
        s += "HKObserverQuery). Wakes and launches the app when new samples land, and unlike location "
        s += "it backfills — HealthKit retains the samples, so a missed wake self-heals on the next "
        s += "one. That asymmetry is the whole reason it ranks this high. Gated by the "
        s += "com.apple.developer.healthkit.background-delivery entitlement, which needs a paid "
        s += "account; the Health section of this report measures whether it survived signing at the "
        s += "current tier. Frequency is capped per type (most types hourly at best; .immediate is "
        s += "honoured for only a few). Does NOT beat the force-quit rule.\n"
        s += "5. BGPROCESSINGTASK. Minutes of runtime, network and external-power predicates, ideal for "
        s += "bulk sync — but entirely at the system's discretion. requiresExternalPower = true makes "
        s += "it far likelier to be granted while confining it to charging-and-idle (in practice, "
        s += "overnight). Requires the \"processing\" background mode and a permitted identifier. Queue "
        s += "ceiling 10. Killed by force-quit and by Background App Refresh being off.\n"
        s += "6. BGAPPREFRESHTASK. ~30 seconds, opportunistic, scheduled against how often the user "
        s += "actually opens the app. earliestBeginDate is a floor, never a schedule; multi-day latency "
        s += "is normal and \"never\" is a legitimate outcome for a rarely-opened app. Requires \"fetch\" "
        s += "and a permitted identifier. Queue ceiling 1. Killed by force-quit and by Background App "
        s += "Refresh being off. This is the mechanism most people reach for first and it is the "
        s += "weakest of the ones worth using.\n\n"

        s += "TIER B — REAL, BUT NOT AVAILABLE TO THIS BUILD:\n"
        s += "7. SILENT REMOTE NOTIFICATIONS (content-available / apns-push-type: background). "
        s += "Server-initiated, which is the property nothing else on this list has. Structurally out "
        s += "of reach here: it needs the \"remote-notification\" background mode (this build declares "
        s += "location/fetch/processing/bluetooth-central — not that one) AND an aps-environment "
        s += "entitlement with an APNs key from a paid account. Even with all of it, silent pushes are "
        s += "explicitly best-effort: they are throttled by the system, deprioritised for apps the user "
        s += "ignores, dropped when Background App Refresh is off, dropped when the device is in Low "
        s += "Power Mode, and NOT delivered to a force-quit app. It is a nudge, never a guarantee. "
        s += "Separately: the VM cannot reach an idle iPhone at all on this project's network, so every "
        s += "transfer must stay phone-initiated regardless.\n"
        s += "8. AUDIO BACKGROUND MODE. The classic keepalive: play silence forever and the process "
        s += "never suspends. It is public API and this app is sideloaded, so App Review's objection "
        s += "does not apply — but it is still the wrong tool. It does not RELAUNCH a terminated app, "
        s += "so it cannot bootstrap itself; it shows in the battery report and in the Control Centre "
        s += "now-playing UI; it fights the system for an audio session with every other app; and it is "
        s += "killed by force-quit and by reboot like everything else. It converts \"woken "
        s += "occasionally\" into \"stays alive once started\", which is a genuinely different "
        s += "capability — just not a foundation. Not declared in this build.\n"
        s += "9. CLBACKGROUNDACTIVITYSESSION (iOS 17). Keeps continuous location updates alive after "
        s += "the app leaves the foreground and puts the honest blue indicator up. Important limitation, "
        s += "widely reported and consistent with its design: a session can only be STARTED from the "
        s += "foreground. An app resurrected into the background cannot create a fresh one, so it "
        s += "cannot be a relaunch mechanism — only a continuation mechanism for a session the user "
        s += "already authorised on screen.\n"
        s += "10. CONTINUOUS BACKGROUND LOCATION (startUpdatingLocation / "
        s += "CLLocationUpdate.liveUpdates with allowsBackgroundLocationUpdates). Highest fidelity, "
        s += "highest power, and it stops SILENTLY the moment the app is terminated with no relaunch "
        s += "and no notification that it stopped. A collector built on this dies quietly, which is the "
        s += "worst possible failure mode. Note also that setting allowsBackgroundLocationUpdates = "
        s += "true WITHOUT the \"location\" background mode is documented as a fatal error that "
        s += "terminates the app — an uncatchable trap, not a throwable error.\n\n"

        s += "THE TWO RULES THAT OVERRIDE EVERYTHING ABOVE:\n"
        s += "• FORCE-QUIT. Swiping the app out of the app switcher is treated by iOS as the user "
        s += "saying they do not want it running — in Apple's words, \"the system accepts this as a "
        s += "signal that the user no longer wishes this app to be running, also in the background.\" "
        s += "Every mechanism on this list stops: BGTask, silent push, HealthKit delivery, audio, "
        s += "Bluetooth restoration. Region monitoring is the documented exception, and it is the "
        s += "reason a serious personal collector is built on geofences rather than on BGTaskScheduler. "
        s += "The suppression lifts when the user next opens the app manually, OR when the device "
        s += "reboots. NOTE FOR CONSISTENCY: the Location section of this report takes the "
        s += "conservative reading that force-quit suppresses relaunch for all location services; the "
        s += "distinction drawn here — region monitoring consistently, SLC and visits not reliably — is "
        s += "Apple DTS's own narrowing. Where the two differ, the launch ledger arbitrates, and that "
        s += "is precisely why it exists.\n"
        s += "• BACKGROUND APP REFRESH OFF. One switch in Settings and iOS relaunches this app for NO "
        s += "background event of any kind — including significant-location-change and region "
        s += "monitoring, which most people assume are exempt. It is invisible from inside CoreLocation "
        s += "and from inside HealthKit; UIApplication.backgroundRefreshStatus is the only API that "
        s += "reports it, which is why this section surfaces it as a first-class denial rather than a "
        s += "footnote. Two smaller cousins: Low Power Mode throttles background work without changing "
        s += "that status at all, and while the device is passcode-locked and has not been unlocked "
        s += "since boot, the system will not launch an app in the background at all.\n\n"

        // --- What this section deliberately did not do -------------------
        s += "DELIBERATE OMISSIONS, so the gaps are auditable rather than invisible:\n"
        s += "• register() is never called from run(). Late or duplicate registration raises "
        s += "NSInternalInconsistencyException (BGTaskScheduler.m:185), an Objective-C exception Swift "
        s += "cannot catch, which would destroy all eleven sections on every run. The full "
        s += "implementation ships in this file as BackgroundProbeScheduler.installAtLaunch() and needs "
        s += "one line in ProbeApp.init() to go live. The constraint is not a probe limitation — it IS "
        s += "the finding, and it is the rule the collector has to be built around.\n"
        s += "• BGContinuedProcessingTask (iOS 26) is detected by NSClassFromString rather than "
        s += "referenced as a symbol, so the build cannot break on an SDK whose exact spelling could "
        s += "not be verified from the build machine. It is user-initiated and shows system progress "
        s += "UI, so it is not a telemetry mechanism regardless of availability.\n"
        s += "• No BGTaskScheduler debug simulation. The _simulateLaunchForTaskWithIdentifier: LLDB "
        s += "hook is private and needs a debugger attached — out of bounds under this project's "
        s += "public-API-only rule, and unavailable on a sideloaded build anyway.\n"
        s += "• Pending requests are left queued rather than cancelled, because the next run's "
        s += "\"before\" read is the experiment. And a vanished request is deliberately reported as "
        s += "SUGGESTIVE of a wake, not proof of one: with no handler registered the system can consume "
        s += "a request without any of this app's code running. That signal only becomes clean once "
        s += "installAtLaunch() is wired in and a real wake writes its own ledger line.\n"

        return s
    }
}
