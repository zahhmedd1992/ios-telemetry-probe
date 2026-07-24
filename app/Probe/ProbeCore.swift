import Foundation
import UIKit

// MARK: - Shared contract
//
// Every probe in Probes/ conforms to `TelemetryProbe` and returns exactly one
// `ProbeSection`. Nothing else is shared between probes, so they can be written
// and compiled independently.
//
// A probe MUST NOT throw, MUST NOT trap, and MUST NOT hang. Anything that can
// fail returns a `.error` item carrying the reason. A probe that crashes takes
// the whole report with it, and the report is the entire point of the app.

enum ProbeStatus: String, Codable {
    case ok            // capability available AND returned real data
    case empty         // capability available, granted, but no data on this device
    case partial       // works, but degraded or with caveats
    case denied        // user or system denied permission
    case notDetermined // never asked, or asked and not yet answered
    case unavailable   // API or hardware not present on this device / OS
    case error         // something failed unexpectedly; see detail
}

struct ProbeItem: Codable, Identifiable {
    let key: String              // stable machine key, e.g. "health.q.HKQuantityTypeIdentifierStepCount"
    let label: String            // human-readable label
    let status: ProbeStatus
    var value: String?           // short human-readable result
    var detail: String?          // longer detail, error text, caveat
    var extra: [String: String]? // free-form structured extras

    var id: String { key }

    init(_ key: String,
         _ label: String,
         _ status: ProbeStatus,
         value: String? = nil,
         detail: String? = nil,
         extra: [String: String]? = nil) {
        self.key = key
        self.label = label
        self.status = status
        self.value = value
        self.detail = detail
        self.extra = extra
    }
}

struct ProbeSection: Codable, Identifiable {
    let key: String
    let title: String
    var summary: String
    var items: [ProbeItem]

    var id: String { key }

    /// Counts by status, used for the section header chips in the UI.
    var tally: [ProbeStatus: Int] {
        var t: [ProbeStatus: Int] = [:]
        for i in items { t[i.status, default: 0] += 1 }
        return t
    }
}

protocol TelemetryProbe {
    /// Stable section key, e.g. "health".
    var key: String { get }
    /// Human-readable section title.
    var title: String { get }
    /// Run the probe. Must always return, never throw.
    func run() async -> ProbeSection
}

extension TelemetryProbe {
    /// Convenience for building the returned section.
    func section(_ summary: String, _ items: [ProbeItem]) -> ProbeSection {
        ProbeSection(key: key, title: title, summary: summary, items: items)
    }
}

// MARK: - Report envelope

struct ProbeReport: Codable {
    let generatedAt: Date
    let schemaVersion: Int
    let app: [String: String]
    let device: [String: String]
    var sections: [ProbeSection]

    /// `@MainActor` because `UIDevice` is main-actor isolated in the current
    /// UIKit overlay; reading `UIDevice.current` from a nonisolated synchronous
    /// context does not compile. The only caller (`ProbeRunner.report`) is
    /// already main-actor isolated, so this costs nothing.
    @MainActor
    static func envelope(sections: [ProbeSection]) -> ProbeReport {
        let b = Bundle.main
        let dev = UIDevice.current
        return ProbeReport(
            generatedAt: Date(),
            schemaVersion: 1,
            app: [
                "bundleIdentifier": b.bundleIdentifier ?? "?",
                "version": (b.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?",
                "build": (b.infoDictionary?["CFBundleVersion"] as? String) ?? "?",
                "installedFrom": b.appStoreReceiptURL?.lastPathComponent ?? "?"
            ],
            device: [
                "model": ProbeEnv.hardwareModel(),
                "marketingName": dev.model,
                "systemName": dev.systemName,
                "systemVersion": dev.systemVersion,
                "name": dev.name,
                "identifierForVendor": dev.identifierForVendor?.uuidString ?? "?",
                "locale": Locale.current.identifier,
                "timeZone": TimeZone.current.identifier,
                "isSimulator": ProbeEnv.isSimulator ? "true" : "false"
            ],
            sections: sections
        )
    }

    func jsonString() -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(self),
              let s = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"encoding failed\"}"
        }
        return s
    }
}

// MARK: - Environment helpers

enum ProbeEnv {
    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    /// e.g. "iPhone16,2"
    static func hardwareModel() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let raw = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        return raw.trimmingCharacters(in: .controlCharacters)
    }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func stamp(_ d: Date?) -> String? {
        guard let d else { return nil }
        return iso.string(from: d)
    }

    /// Human-readable "3.2 days ago" style age, for eyeballing backfill windows.
    static func age(_ d: Date?) -> String? {
        guard let d else { return nil }
        let secs = Date().timeIntervalSince(d)
        if secs < 90 { return String(format: "%.0fs ago", secs) }
        if secs < 5400 { return String(format: "%.1f min ago", secs / 60) }
        if secs < 172_800 { return String(format: "%.1f hr ago", secs / 3600) }
        return String(format: "%.1f days ago", secs / 86_400)
    }

    static func num(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    static func int(_ v: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }
}

/// One-shot claim ticket so the worker arm and the deadline arm of
/// `withProbeTimeout` cannot both resume the same continuation.
private final class ProbeTimeoutGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    /// Returns true exactly once, for the first caller.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// Runs an async operation with a hard deadline so one wedged framework call
/// cannot stall the whole report. Returns `fallback` on timeout.
///
/// DELIBERATELY NOT a `withTaskGroup`. Two reasons, both load-bearing:
///
///  1. `TaskGroup` is declared `where ChildTaskResult: Sendable`, so a group
///     parameterised on an unconstrained `T` does not compile. Adding
///     `T: Sendable` would then push the constraint out to all 25 call sites.
///  2. More importantly, a task group implicitly AWAITS its remaining children
///     when the body returns. `cancelAll()` does not help, because
///     `withCheckedContinuation` is not cancellation-aware — so a probe parked
///     on a callback that never fires would hang here forever rather than time
///     out. Since ProbeRunner's own 180 s per-section cap also routes through
///     this function, that single hang would take the entire report with it.
///
/// This variant races two independent tasks against one continuation and
/// resumes on whichever arm wins, so it always returns on the deadline.
/// TRADE-OFF, stated plainly: the losing worker is ABANDONED, not awaited. On a
/// timeout the probe body keeps running detached (it may still hold the audio
/// session, a location manager, or a photo enumeration) while the runner starts
/// the next section. That is the correct trade — a contaminated tail after a
/// timeout that should never fire beats a permanent hang with no report at all.
func withProbeTimeout<T>(_ seconds: Double,
                         fallback: T,
                         _ work: @escaping () async -> T) async -> T {
    let gate = ProbeTimeoutGate()
    return await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
        let worker = Task {
            let value = await work()
            if gate.claim() { cont.resume(returning: value) }
        }
        Task {
            let ns = UInt64(max(0, seconds) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: ns)
            if gate.claim() {
                worker.cancel()
                cont.resume(returning: fallback)
            }
        }
    }
}

// MARK: - Runner

@MainActor
final class ProbeRunner: ObservableObject {
    @Published var sections: [ProbeSection] = []
    @Published var running = false
    @Published var progressLabel = ""
    @Published var completed = 0
    @Published var total = 0

    /// Registration order is display order. Permission-prompting probes run
    /// first and sequentially, because iOS will only present one system
    /// permission sheet at a time and racing them drops prompts silently.
    private let probes: [TelemetryProbe] = [
        EntitlementProbe(),
        HealthProbe(),
        MotionProbe(),
        LocationProbe(),
        StoresProbe(),
        AmbientProbe(),
        NetworkProbe(),
        DeviceProbe(),
        FocusProbe(),
        IntentsProbe(),
        BackgroundProbe()
    ]

    func runAll() async {
        guard !running else { return }
        running = true
        sections = []
        completed = 0
        total = probes.count

        for p in probes {
            progressLabel = p.title
            let s = await withProbeTimeout(
                180,
                fallback: ProbeSection(
                    key: p.key,
                    title: p.title,
                    summary: "Timed out after 180s — the framework call never returned.",
                    items: [ProbeItem("\(p.key).timeout", "Probe timed out", .error)]
                )
            ) {
                await p.run()
            }
            sections.append(s)
            completed += 1
        }

        progressLabel = ""
        running = false
    }

    var report: ProbeReport { ProbeReport.envelope(sections: sections) }

    /// Written to the app's Documents dir on every run so the result survives
    /// a crash and can be pulled off the phone over USB via the Files app.
    func persist() -> URL? {
        let json = report.jsonString()
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let dir else { return nil }
        let url = dir.appendingPathComponent("probe-report.json")
        try? json.data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }
}
