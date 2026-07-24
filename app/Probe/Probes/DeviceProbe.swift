import Foundation
import CoreFoundation
import UIKit
import AVFoundation
import AVFAudio
import UserNotifications
import Darwin
import os

// MARK: - DeviceProbe
//
// "Device & System State" = everything the phone will tell us about ITSELF with
// no permission prompt beyond notifications. Battery, thermals, memory, storage,
// uptime, screen, volume, orientation, locale, accessibility settings, lock
// state, screenshots, notification authorization, app lifecycle, pasteboard.
//
// Design notes that matter for the collector that comes after this probe:
//
//  1. HALF THE VALUE HERE IS CROSS-RUN, NOT SINGLE-RUN.
//     Three questions cannot be answered by one foreground snapshot:
//       * do the springboard lock Darwin notifications still fire on iOS 26?
//       * does the screenshot notification fire?
//       * has the phone rebooted since we last looked?
//     So this probe ARMS PERSISTENT OBSERVERS and keeps counters in
//     UserDefaults (`DeviceProbeLedger`). Run the probe, lock/unlock the phone,
//     take a screenshot, run it again — the second run's counters are the
//     ground truth. A count of 0 on the first run means nothing; a count of 0
//     on the second run after you demonstrably locked the phone is a finding.
//
//  2. WE MEASURE BOOT TIME TWO WAYS ON PURPOSE.
//     `now - ProcessInfo.systemUptime` and `sysctl kern.boottime` disagree, and
//     the size of the disagreement is itself the datum (it accumulates while the
//     device sleeps, and kern.boottime is re-anchored by NTP). Only
//     kern.boottime is stable enough to key a reboot log off.
//
//  3. THIS PROBE MUST NOT DEGRADE THE DEVICE IT MEASURES.
//     It never writes UIScreen.brightness (that silently disables
//     Auto-Brightness in Settings), never leaves proximity monitoring on (it
//     blanks the display), and restores AVAudioSession state after reading
//     the volume.
//
// Deliberately NOT included, and why:
//   * `UIPasteboard.detectPatterns(...)` — genuinely useful (pattern detection
//     without the paste banner) but the exact Swift signature of its Result
//     completion handler could not be verified against developer.apple.com at
//     authoring time, and there is no Mac to compile against. Omitted rather
//     than risk the shared build. Worth adding once a build is green.
//   * `UIAccessibility.buttonShapesEnabled` — documented as deprecated on the
//     current SDK; omitted for one boolean of fingerprint value.
//   * Anything that reads pasteboard CONTENT. On iOS 16+ that raises a
//     user-visible "Probe pasted from X" banner, which makes it unusable as a
//     passive signal. Only `changeCount` and the `has*` predicates are read.

struct DeviceProbe: TelemetryProbe {
    let key = "device"
    let title = "Device & System State"

    /// How long we will wait for a human to answer the notification prompt.
    /// Well inside the runner's 180s per-probe deadline.
    static let notificationPromptTimeout: Double = 60.0

    /// Poll budget for values that return sentinel junk on first read.
    static let settlePollCount = 20          // × 50ms = 1.0s
    static let settlePollNanos: UInt64 = 50_000_000

    func run() async -> ProbeSection {
        var items: [ProbeItem] = []

        // Arm the cross-run observers FIRST so anything that happens during the
        // rest of this run is already being counted.
        items.append(await DeviceProbeLedger.arm())

        items.append(contentsOf: await readBattery())
        items.append(readThermal())
        items.append(contentsOf: readMemory())
        items.append(contentsOf: readStorage())
        items.append(contentsOf: readUptime())
        items.append(contentsOf: await readScreen())
        items.append(contentsOf: readVolume())
        items.append(contentsOf: await readOrientationAndProximity())
        items.append(contentsOf: readLocaleAndTime())
        items.append(contentsOf: await readAccessibility())
        items.append(contentsOf: await readLockState())
        items.append(contentsOf: await readScreenshotDetection())
        items.append(contentsOf: await readNotifications())
        items.append(contentsOf: await readLifecycle())
        items.append(contentsOf: await readPasteboard())

        return section(DeviceProbeSummary.build(items), items)
    }
}

// MARK: - Exactly-once continuation plumbing
//
// Same reasoning as elsewhere in this app: the contract's `withProbeTimeout`
// uses a task group, which implicitly awaits its children, so an unresumed
// continuation nested inside it HANGS rather than times out. Every deadline
// therefore lives inside the continuation.

final class DeviceProbeResumeGuard: @unchecked Sendable {
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

enum DeviceProbeAwait {
    /// Bridges a completion-handler API into async with a hard internal deadline.
    static func once<T>(timeout: Double,
                        timeoutValue: T,
                        _ body: @escaping (@escaping (T) -> Void) -> Void) async -> T {
        await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
            let guardBox = DeviceProbeResumeGuard()
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                if guardBox.claim() { cont.resume(returning: timeoutValue) }
            }
            body { value in
                if guardBox.claim() { cont.resume(returning: value) }
            }
        }
    }
}

// MARK: - Formatting helpers (prefixed; do not un-prefix)

enum DeviceProbeFmt {
    static func bool(_ b: Bool) -> String { b ? "true" : "false" }
    static func f2(_ v: Double) -> String { String(format: "%.2f", v) }
    static func f3(_ v: Double) -> String { String(format: "%.3f", v) }
    static func pct(_ v: Float) -> String { String(format: "%.0f%%", v * 100) }

    static func bytes(_ v: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useGB, .useMB, .useKB]
        return f.string(fromByteCount: v)
    }
    static func bytes(_ v: UInt64) -> String { bytes(Int64(clamping: v)) }
    static func bytes(_ v: Int) -> String { bytes(Int64(v)) }

    static func duration(_ secs: Double) -> String {
        if secs < 0 { return "n/a" }
        let d = Int(secs) / 86_400
        let h = (Int(secs) % 86_400) / 3600
        let m = (Int(secs) % 3600) / 60
        let s = Int(secs) % 60
        if d > 0 { return "\(d)d \(h)h \(m)m" }
        if h > 0 { return "\(h)h \(m)m \(s)s" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    static func battery(_ s: UIDevice.BatteryState) -> String {
        switch s {
        case .unknown:  return "unknown"
        case .unplugged: return "unplugged"
        case .charging: return "charging"
        case .full:     return "full"
        @unknown default: return "unknown(\(s.rawValue))"
        }
    }

    static func thermal(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown(\(s.rawValue))"
        }
    }

    static func deviceOrientation(_ o: UIDeviceOrientation) -> String {
        switch o {
        case .unknown:            return "unknown"
        case .portrait:           return "portrait"
        case .portraitUpsideDown: return "portraitUpsideDown"
        case .landscapeLeft:      return "landscapeLeft"
        case .landscapeRight:     return "landscapeRight"
        case .faceUp:             return "faceUp"
        case .faceDown:           return "faceDown"
        @unknown default:         return "unknown(\(o.rawValue))"
        }
    }

    static func interfaceOrientation(_ o: UIInterfaceOrientation) -> String {
        switch o {
        case .unknown:            return "unknown"
        case .portrait:           return "portrait"
        case .portraitUpsideDown: return "portraitUpsideDown"
        case .landscapeLeft:      return "landscapeLeft"
        case .landscapeRight:     return "landscapeRight"
        @unknown default:         return "unknown(\(o.rawValue))"
        }
    }

    static func appState(_ s: UIApplication.State) -> String {
        switch s {
        case .active:     return "active"
        case .inactive:   return "inactive"
        case .background: return "background"
        @unknown default: return "unknown(\(s.rawValue))"
        }
    }

    static func proximity(_ enabled: Bool, _ state: Bool) -> String {
        guard enabled else { return "monitoring unavailable" }
        return state ? "near (object detected)" : "far (clear)"
    }

    // -- UserNotifications enums. rawValue-based where the Swift case name is
    //    ambiguous with Optional (`UNAlertStyle.none`).

    static func unAuthStatus(_ s: UNAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: return "notDetermined"
        case .denied:        return "denied"
        case .authorized:    return "authorized"
        case .provisional:   return "provisional"
        case .ephemeral:     return "ephemeral"
        @unknown default:    return "unknown(\(s.rawValue))"
        }
    }

    static func unSetting(_ s: UNNotificationSetting) -> String {
        switch s {
        case .notSupported: return "notSupported"
        case .disabled:     return "disabled"
        case .enabled:      return "enabled"
        @unknown default:   return "unknown(\(s.rawValue))"
        }
    }

    static func unAlertStyle(_ s: UNAlertStyle) -> String {
        switch s.rawValue {
        case 0:  return "none"
        case 1:  return "banner"
        case 2:  return "alert"
        default: return "unknown(\(s.rawValue))"
        }
    }

    static func unShowPreviews(_ s: UNShowPreviewsSetting) -> String {
        switch s {
        case .always:            return "always"
        case .whenAuthenticated: return "whenAuthenticated"
        case .never:             return "never"
        @unknown default:        return "unknown(\(s.rawValue))"
        }
    }

    /// Stable across launches, unlike Swift's per-process-seeded Hasher.
    /// FNV-1a 64. Used to turn the accessibility settings vector into one
    /// comparable token so change detection is a single string compare.
    static func stableHash(_ s: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x1000_0000_01b3
        }
        return String(format: "%016llx", h)
    }
}

// MARK: - Cross-run ledger
//
// The single most valuable thing in this file. A foreground probe cannot lock
// the phone, so a one-shot "did the lock notification fire?" test is worthless.
// Instead we arm observers, persist counters, and let the SECOND run answer it.
//
// Hard caveat, stated in every item that reads from here: these observers only
// live while the process lives. iOS suspends and eventually terminates a
// backgrounded app, and nothing is counted while it is dead. So a nonzero count
// proves the notification fires; a zero count proves nothing on its own.

enum DeviceProbeLedger {
    private static let d = UserDefaults.standard
    private static let lock = NSLock()
    private static var armed = false
    private static var tokens: [NSObjectProtocol] = []

    // All keys prefixed. Never shorten these — they are the persistence schema.
    static let kArmedAt          = "DeviceProbe.ledger.armedAt"
    static let kArmCount         = "DeviceProbe.ledger.armCount"
    static let kDarwinLastFired  = "DeviceProbe.darwin.lastFired"
    static let kLockState        = "DeviceProbe.darwin.lockstate.count"
    static let kLockComplete     = "DeviceProbe.darwin.lockcomplete.count"
    static let kScreenshot       = "DeviceProbe.screenshot.count"
    static let kScreenshotLast   = "DeviceProbe.screenshot.last"
    static let kCaptured         = "DeviceProbe.captured.count"
    static let kCapturedLast     = "DeviceProbe.captured.last"
    static let kProtectedAvail   = "DeviceProbe.protectedData.available.count"
    static let kProtectedUnavail = "DeviceProbe.protectedData.unavailable.count"
    static let kProtectedLast    = "DeviceProbe.protectedData.last"
    static let kDidBecomeActive  = "DeviceProbe.lifecycle.didBecomeActive.count"
    static let kDidEnterBg       = "DeviceProbe.lifecycle.didEnterBackground.count"
    static let kWillResign       = "DeviceProbe.lifecycle.willResignActive.count"
    static let kWillEnterFg      = "DeviceProbe.lifecycle.willEnterForeground.count"
    static let kBootAnchor       = "DeviceProbe.boot.anchorEpoch"
    static let kRebootCount      = "DeviceProbe.boot.rebootCount"
    static let kRebootLog        = "DeviceProbe.boot.log"
    static let kPasteChange      = "DeviceProbe.pasteboard.lastChangeCount"
    static let kPasteSeenAt      = "DeviceProbe.pasteboard.lastSeenAt"

    static let lockStateName    = "com.apple.springboard.lockstate"
    static let lockCompleteName = "com.apple.springboard.lockcomplete"

    static func bump(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        d.set(d.integer(forKey: key) + 1, forKey: key)
    }

    static func count(_ key: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return d.integer(forKey: key)
    }

    static func setInt(_ key: String, _ value: Int) {
        lock.lock(); defer { lock.unlock() }
        d.set(value, forKey: key)
    }

    static func has(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return d.object(forKey: key) != nil
    }

    static func setString(_ key: String, _ value: String) {
        lock.lock(); defer { lock.unlock() }
        d.set(value, forKey: key)
    }

    static func string(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return d.string(forKey: key)
    }

    static func setDouble(_ key: String, _ value: Double) {
        lock.lock(); defer { lock.unlock() }
        d.set(value, forKey: key)
    }

    static func double(_ key: String) -> Double? {
        lock.lock(); defer { lock.unlock() }
        return d.object(forKey: key) == nil ? nil : d.double(forKey: key)
    }

    static func strings(_ key: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return d.stringArray(forKey: key) ?? []
    }

    static func setStrings(_ key: String, _ value: [String]) {
        lock.lock(); defer { lock.unlock() }
        d.set(value, forKey: key)
    }

    /// Idempotent. Registers the Darwin, screenshot, capture, protected-data and
    /// lifecycle observers exactly once per process.
    @MainActor
    static func arm() async -> ProbeItem {
        let alreadyArmed: Bool = { () -> Bool in
            lock.lock(); defer { lock.unlock() }
            if armed { return true }
            armed = true
            return false
        }()

        let firstArm = string(kArmedAt) == nil
        if firstArm { setString(kArmedAt, ProbeEnv.iso.string(from: Date())) }

        if alreadyArmed {
            return ProbeItem(
                "device.ledger", "Cross-run event ledger", .ok,
                value: "already armed this launch",
                detail: "Observers were registered earlier in this process; not re-registering.",
                extra: snapshotExtra()
            )
        }

        bump(kArmCount)

        // --- Darwin notify center (springboard lock state) -------------------
        //
        // One dedicated non-capturing closure per notification name. A
        // CFNotificationCallback is @convention(c) and cannot capture context,
        // but referencing global/static members is not capture, so this is
        // legal — and it means we never have to spell out the callback's
        // parameter types (the `name` argument's Swift type is
        // CFNotificationName? on some SDK versions and CFString? on others,
        // and getting it wrong would not compile). Ignoring all five params
        // sidesteps that entirely.
        let darwin = CFNotificationCenterGetDarwinNotifyCenter()

        CFNotificationCenterAddObserver(
            darwin, nil,
            { _, _, _, _, _ in
                DeviceProbeLedger.bump(DeviceProbeLedger.kLockState)
                DeviceProbeLedger.setString(
                    DeviceProbeLedger.kDarwinLastFired,
                    "\(DeviceProbeLedger.lockStateName) @ \(ProbeEnv.iso.string(from: Date()))")
            },
            lockStateName as CFString, nil, .deliverImmediately)

        CFNotificationCenterAddObserver(
            darwin, nil,
            { _, _, _, _, _ in
                DeviceProbeLedger.bump(DeviceProbeLedger.kLockComplete)
                DeviceProbeLedger.setString(
                    DeviceProbeLedger.kDarwinLastFired,
                    "\(DeviceProbeLedger.lockCompleteName) @ \(ProbeEnv.iso.string(from: Date()))")
            },
            lockCompleteName as CFString, nil, .deliverImmediately)

        // --- Foundation notification center ----------------------------------
        let nc = NotificationCenter.default
        func observe(_ name: Notification.Name, _ key: String, _ lastKey: String?) {
            let t = nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                DeviceProbeLedger.bump(key)
                if let lastKey {
                    DeviceProbeLedger.setString(lastKey, ProbeEnv.iso.string(from: Date()))
                }
            }
            tokens.append(t)
        }

        observe(UIApplication.userDidTakeScreenshotNotification, kScreenshot, kScreenshotLast)
        observe(UIScreen.capturedDidChangeNotification, kCaptured, kCapturedLast)
        observe(UIApplication.protectedDataDidBecomeAvailableNotification, kProtectedAvail, kProtectedLast)
        observe(UIApplication.protectedDataWillBecomeUnavailableNotification, kProtectedUnavail, kProtectedLast)
        observe(UIApplication.didBecomeActiveNotification, kDidBecomeActive, nil)
        observe(UIApplication.didEnterBackgroundNotification, kDidEnterBg, nil)
        observe(UIApplication.willResignActiveNotification, kWillResign, nil)
        observe(UIApplication.willEnterForegroundNotification, kWillEnterFg, nil)

        return ProbeItem(
            "device.ledger", "Cross-run event ledger", .ok,
            value: firstArm ? "armed for the first time" : "re-armed (launch #\(count(kArmCount)))",
            detail: """
            Observers are now live for: springboard lockstate/lockcomplete (Darwin), \
            screenshot, screen-capture change, protected-data availability, and the four \
            app lifecycle transitions. Counters persist in UserDefaults across launches.

            HOW TO READ THIS SECTION: counters only advance while this process is alive. \
            iOS suspends and eventually kills a backgrounded app, and nothing is recorded \
            while it is dead. A NONZERO count therefore proves the notification fires on \
            this OS build; a ZERO count proves nothing by itself.

            TO GET THE ANSWER: run the probe, leave the app in the foreground, lock the \
            phone with the side button, unlock it, take a screenshot, then run the probe \
            again and read the counts below.
            """,
            extra: snapshotExtra()
        )
    }

    static func snapshotExtra() -> [String: String] {
        var e: [String: String] = [
            "armedAt": string(kArmedAt) ?? "never",
            "armCount": ProbeEnv.int(count(kArmCount)),
            "lockstateCount": ProbeEnv.int(count(kLockState)),
            "lockcompleteCount": ProbeEnv.int(count(kLockComplete)),
            "screenshotCount": ProbeEnv.int(count(kScreenshot)),
            "capturedChangeCount": ProbeEnv.int(count(kCaptured)),
            "protectedDataAvailableCount": ProbeEnv.int(count(kProtectedAvail)),
            "protectedDataUnavailableCount": ProbeEnv.int(count(kProtectedUnavail)),
            "didBecomeActiveCount": ProbeEnv.int(count(kDidBecomeActive)),
            "didEnterBackgroundCount": ProbeEnv.int(count(kDidEnterBg))
        ]
        if let s = string(kDarwinLastFired) { e["darwinLastFired"] = s }
        return e
    }
}

// MARK: - sysctl / mach helpers

enum DeviceProbeSysctl {
    /// True wall-clock boot timestamp from `kern.boottime`. Unlike
    /// `now - systemUptime` this does not drift every time you read it — but it
    /// IS re-anchored when the clock is corrected by NTP, so a small jump is
    /// expected and does not mean the device rebooted.
    static func bootTime() -> Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        let r = sysctlbyname("kern.boottime", &tv, &size, nil, 0)
        guard r == 0, tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }

    static func stringValue(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    static func int64Value(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.stride
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}

enum DeviceProbeMemory {
    /// This process's real physical footprint — the number iOS actually kills
    /// you on, which is NOT the same as resident size.
    static func footprint() -> (phys: UInt64, resident: UInt64)? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size /
                                           MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { p -> kern_return_t in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { ip in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), ip, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        // Explicit UInt64() rather than relying on the mach_vm_size_t typealias.
        return (UInt64(info.phys_footprint), UInt64(info.resident_size))
    }
}

// MARK: - 1. Battery

extension DeviceProbe {

    @MainActor
    func readBattery() async -> [ProbeItem] {
        var items: [ProbeItem] = []
        let dev = UIDevice.current
        let wasEnabled = dev.isBatteryMonitoringEnabled
        dev.isBatteryMonitoringEnabled = true
        let enableTook = dev.isBatteryMonitoringEnabled

        // batteryLevel returns -1.0 until the first reading lands. Poll, do not
        // guess a fixed sleep — the settle time varies with device state.
        var level = dev.batteryLevel
        var polls = 0
        while level < 0 && polls < DeviceProbe.settlePollCount {
            try? await Task.sleep(nanoseconds: DeviceProbe.settlePollNanos)
            level = dev.batteryLevel
            polls += 1
        }
        let state = dev.batteryState
        let settleMs = polls * 50

        if !enableTook {
            items.append(ProbeItem(
                "device.battery.level", "Battery level", .unavailable,
                value: "monitoring could not be enabled",
                detail: "UIDevice.isBatteryMonitoringEnabled read back false after being set true."
            ))
        } else if level < 0 {
            items.append(ProbeItem(
                "device.battery.level", "Battery level", .partial,
                value: "-1 (never settled)",
                detail: "Battery monitoring enabled, but batteryLevel stayed at the -1.0 sentinel "
                      + "for \(settleMs)ms of polling. This is the documented behaviour in the "
                      + "Simulator; on real hardware it should resolve within a few hundred ms.",
                extra: ["raw": DeviceProbeFmt.f3(Double(level)),
                        "settleMs": ProbeEnv.int(settleMs),
                        "isSimulator": DeviceProbeFmt.bool(ProbeEnv.isSimulator)]
            ))
        } else {
            // Real hardware quantises to 5% steps. Recording the raw float tells
            // the collector how finely it can ever trend this series.
            let pctValue = Double(level) * 100
            let isFivePercentStep = abs(pctValue.rounded() - (pctValue / 5).rounded() * 5) < 0.001
            items.append(ProbeItem(
                "device.battery.level", "Battery level", .ok,
                value: DeviceProbeFmt.pct(level),
                detail: "Raw float \(DeviceProbeFmt.f3(Double(level))). iOS quantises this to 5% "
                      + "steps on real hardware, so the useful sampling rate for a battery series "
                      + "is 'on change', never on a timer. Settled after \(settleMs)ms.",
                extra: ["raw": DeviceProbeFmt.f3(Double(level)),
                        "percent": DeviceProbeFmt.f2(pctValue),
                        "looksQuantisedTo5Percent": DeviceProbeFmt.bool(isFivePercentStep),
                        "settleMs": ProbeEnv.int(settleMs)]
            ))
        }

        items.append(ProbeItem(
            "device.battery.state", "Battery state", state == .unknown ? .partial : .ok,
            value: DeviceProbeFmt.battery(state),
            detail: "unplugged / charging / full / unknown. Note there is NO public API for "
                  + "battery health, cycle count, voltage, temperature or wattage — those live in "
                  + "the private IOKit AppleSmartBattery service and are out of scope for a "
                  + "public-API build.",
            extra: ["raw": ProbeEnv.int(state.rawValue),
                    "monitoringWasAlreadyOn": DeviceProbeFmt.bool(wasEnabled)]
        ))

        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        items.append(ProbeItem(
            "device.battery.lowPowerMode", "Low Power Mode", .ok,
            value: DeviceProbeFmt.bool(lowPower),
            detail: "ProcessInfo.isLowPowerModeEnabled. This is a first-class collector signal in "
                  + "both directions: it changes user behaviour AND it throttles background "
                  + "execution, so a gap in background-collected data should always be correlated "
                  + "against this flag before it is treated as a bug."
        ))

        // Compile-verified Swift spellings, reported by rawValue so the collector
        // author can copy the exact symbol rather than guessing the string.
        items.append(ProbeItem(
            "device.battery.notifications", "Battery change notifications", .ok,
            value: "3 observable",
            detail: "All three compile against this SDK. batteryLevel/batteryState notifications "
                  + "require isBatteryMonitoringEnabled to remain true — this probe leaves it ON "
                  + "deliberately, since turning it off would silence the collector.",
            extra: [
                "UIDevice.batteryLevelDidChangeNotification":
                    UIDevice.batteryLevelDidChangeNotification.rawValue,
                "UIDevice.batteryStateDidChangeNotification":
                    UIDevice.batteryStateDidChangeNotification.rawValue,
                "NSNotification.Name.NSProcessInfoPowerStateDidChange":
                    NSNotification.Name.NSProcessInfoPowerStateDidChange.rawValue,
                "monitoringLeftEnabled": "true"
            ]
        ))

        return items
    }
}

// MARK: - 2. Thermal

extension DeviceProbe {

    func readThermal() -> ProbeItem {
        let s = ProcessInfo.processInfo.thermalState
        return ProbeItem(
            "device.thermal", "Thermal state", .ok,
            value: DeviceProbeFmt.thermal(s),
            detail: "ProcessInfo.thermalState. Four buckets only — there is no public API for the "
                  + "actual die temperature in degrees. `.serious` and `.critical` are the states "
                  + "where iOS throttles the CPU/GPU and suppresses background work, so like Low "
                  + "Power Mode this is a confounder to check before calling a data gap a bug.",
            extra: [
                "raw": ProbeEnv.int(s.rawValue),
                "ProcessInfo.thermalStateDidChangeNotification":
                    ProcessInfo.thermalStateDidChangeNotification.rawValue
            ]
        )
    }
}

// MARK: - 3. Memory & CPU

extension DeviceProbe {

    func readMemory() -> [ProbeItem] {
        var items: [ProbeItem] = []
        let pi = ProcessInfo.processInfo

        let phys = pi.physicalMemory
        items.append(ProbeItem(
            "device.memory.physical", "Physical memory", .ok,
            value: DeviceProbeFmt.bytes(phys),
            detail: "ProcessInfo.physicalMemory — total RAM installed, not what this app may use.",
            extra: ["bytes": ProbeEnv.int(Int(clamping: phys))]
        ))

        // os_proc_available_memory() is the only public way to see how much
        // headroom remains before the jetsam killer fires. It returns 0 when
        // called from something that is not a foreground app.
        //
        // BUILD NOTE — this is the single least-verified symbol in this file.
        // It lives in <os/proc.h> (iOS 13+) and is reached through `import os`,
        // but its exposure to Swift rests on a developer-forum sample rather
        // than on documentation, and there is no Mac in this project to compile
        // against. `#if canImport(os)` would NOT protect it: the module imports
        // fine either way, the open question is whether the symbol is surfaced.
        // IF CI FAILS ON THIS LINE, delete this item and nothing else breaks —
        // DeviceProbeMemory.footprint() below already reports phys_footprint, so
        // the section loses one number and no structure.
        let avail = os_proc_available_memory()
        if avail > 0 {
            let ratio = Double(avail) / Double(phys) * 100
            items.append(ProbeItem(
                "device.memory.available", "App memory headroom", .ok,
                value: DeviceProbeFmt.bytes(avail),
                detail: "os_proc_available_memory() — bytes this process may still allocate before "
                      + "iOS terminates it. That is \(DeviceProbeFmt.f2(ratio))% of installed RAM; "
                      + "the per-app cap is far below total RAM and varies by device model. The "
                      + "com.apple.developer.kernel.increased-memory-limit entitlement raises it on "
                      + "eligible hardware — see EntitlementProbe for whether we can sign for it.",
                extra: ["bytes": ProbeEnv.int(avail),
                        "percentOfPhysicalRAM": DeviceProbeFmt.f2(ratio)]
            ))
        } else {
            items.append(ProbeItem(
                "device.memory.available", "App memory headroom", .partial,
                value: "0",
                detail: "os_proc_available_memory() returned 0, which it does for processes that "
                      + "are not apps (and in some Simulator configurations). The symbol linked and "
                      + "the call succeeded — only the value is unusable here."
            ))
        }

        if let fp = DeviceProbeMemory.footprint() {
            items.append(ProbeItem(
                "device.memory.footprint", "This process's footprint", .ok,
                value: DeviceProbeFmt.bytes(fp.phys),
                detail: "task_info(TASK_VM_INFO).phys_footprint — the number jetsam actually "
                      + "measures against the limit. Resident size is \(DeviceProbeFmt.bytes(fp.resident)), "
                      + "and the two differ because footprint excludes clean file-backed pages. "
                      + "A collector should log footprint, never resident size.",
                extra: ["physFootprintBytes": ProbeEnv.int(Int(clamping: fp.phys)),
                        "residentSizeBytes": ProbeEnv.int(Int(clamping: fp.resident))]
            ))
        } else {
            items.append(ProbeItem(
                "device.memory.footprint", "This process's footprint", .error,
                detail: "task_info(TASK_VM_INFO) did not return KERN_SUCCESS."
            ))
        }

        items.append(ProbeItem(
            "device.cpu.count", "Processor cores", .ok,
            value: "\(pi.activeProcessorCount) active of \(pi.processorCount)",
            detail: "activeProcessorCount can drop below processorCount when iOS parks cores under "
                  + "thermal pressure or Low Power Mode, so sampling both is a cheap proxy for "
                  + "system-level throttling.",
            extra: ["processorCount": ProbeEnv.int(pi.processorCount),
                    "activeProcessorCount": ProbeEnv.int(pi.activeProcessorCount),
                    "hwModel": ProbeEnv.hardwareModel(),
                    "hwMachineArch": DeviceProbeSysctl.stringValue("hw.machine") ?? "?",
                    "hwMemsize": DeviceProbeSysctl.int64Value("hw.memsize").map { String($0) } ?? "?"]
        ))

        return items
    }
}

// MARK: - 4. Storage

extension DeviceProbe {

    func readStorage() -> [ProbeItem] {
        var items: [ProbeItem] = []
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityForOpportunisticUsageKey,
            .volumeNameKey,
            .volumeIsInternalKey
        ]

        guard let v = try? home.resourceValues(forKeys: keys) else {
            items.append(ProbeItem(
                "device.storage", "Storage capacity", .error,
                detail: "URL.resourceValues(forKeys:) threw for the app's home directory."
            ))
            return items
        }

        let total = v.volumeTotalCapacity
        let plain = v.volumeAvailableCapacity
        let important = v.volumeAvailableCapacityForImportantUsage
        let opportunistic = v.volumeAvailableCapacityForOpportunisticUsage

        var extra: [String: String] = [:]
        if let total { extra["volumeTotalCapacity"] = ProbeEnv.int(total) }
        if let plain { extra["volumeAvailableCapacity"] = ProbeEnv.int(plain) }
        if let important { extra["volumeAvailableCapacityForImportantUsage"] = String(important) }
        if let opportunistic { extra["volumeAvailableCapacityForOpportunisticUsage"] = String(opportunistic) }
        if let n = v.volumeName { extra["volumeName"] = n }

        // The legacy API is kept as a deliberate cross-check: it reports a
        // materially different (larger) free figure because it ignores purgeable
        // space accounting. Which number a collector logs changes the answer.
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()) {
            if let free = attrs[.systemFreeSize] as? NSNumber {
                extra["legacy.systemFreeSize"] = ProbeEnv.int(free.intValue)
            }
            if let size = attrs[.systemSize] as? NSNumber {
                extra["legacy.systemSize"] = ProbeEnv.int(size.intValue)
            }
        }

        let status: ProbeStatus = (total != nil && important != nil) ? .ok : .partial

        var capacityValue = "partially resolved"
        if let totalValue = total, let importantValue = important {
            capacityValue = "\(DeviceProbeFmt.bytes(importantValue)) free of "
                          + "\(DeviceProbeFmt.bytes(totalValue))"
        }

        items.append(ProbeItem(
            "device.storage.capacity", "Storage capacity", status,
            value: capacityValue,
            detail: """
            Four different numbers, and they genuinely disagree — this is the finding, not a bug:

            • volumeTotalCapacity: \(total.map { DeviceProbeFmt.bytes($0) } ?? "nil")
            • volumeAvailableCapacity: \(plain.map { DeviceProbeFmt.bytes($0) } ?? "nil")
              — the naive free-space figure; ignores purgeable content.
            • ...ForImportantUsage: \(important.map { DeviceProbeFmt.bytes($0) } ?? "nil")
              — what you can write for data the user WILL miss (a photo, a database).
              iOS will purge caches to honour this, so it is the LARGEST of the free figures.
            • ...ForOpportunisticUsage: \(opportunistic.map { DeviceProbeFmt.bytes($0) } ?? "nil")
              — what you can write for regenerable data (a prefetch, a cache).

            A telemetry collector writing its own SQLite database should size against
            ForImportantUsage and back off against ForOpportunisticUsage. The legacy
            FileManager .systemFreeSize value is recorded in `extra` as a cross-check; it is
            usually the most optimistic of the set and should not be used for sizing.
            """,
            extra: extra
        ))

        return items
    }
}

// MARK: - 5. Uptime, boot time, and the reboot log

extension DeviceProbe {

    func readUptime() -> [ProbeItem] {
        var items: [ProbeItem] = []
        let pi = ProcessInfo.processInfo
        let now = Date()
        let uptime = pi.systemUptime
        let derivedBoot = now.addingTimeInterval(-uptime)
        let sysctlBoot = DeviceProbeSysctl.bootTime()

        items.append(ProbeItem(
            "device.uptime", "System uptime", .ok,
            value: DeviceProbeFmt.duration(uptime),
            detail: "ProcessInfo.systemUptime — seconds since boot on the monotonic clock. It is "
                  + "immune to clock changes, which makes it the right basis for measuring "
                  + "intervals, and useless as an absolute timestamp.",
            extra: ["seconds": DeviceProbeFmt.f3(uptime),
                    "days": DeviceProbeFmt.f2(uptime / 86_400)]
        ))

        if let sysctlBoot {
            let delta = sysctlBoot.timeIntervalSince(derivedBoot)
            items.append(ProbeItem(
                "device.bootTime", "Boot timestamp", .ok,
                value: ProbeEnv.stamp(sysctlBoot) ?? "?",
                detail: """
                Two independent derivations, and they disagree by \
                \(DeviceProbeFmt.f3(abs(delta)))s. That disagreement is the point:

                • sysctl kern.boottime → \(ProbeEnv.stamp(sysctlBoot) ?? "?")
                  Wall-clock boot instant recorded by the kernel. Stable to read repeatedly,
                  but re-anchored whenever the clock is corrected by NTP.
                • now − systemUptime → \(ProbeEnv.stamp(derivedBoot) ?? "?")
                  Moves slightly every time you compute it, because the two clocks drift.

                For a reboot log, key off kern.boottime and treat a shift of more than a few
                seconds as a genuine reboot. \(ProbeEnv.age(sysctlBoot).map { "Booted \($0)." } ?? "")
                """,
                extra: ["kernBoottime": ProbeEnv.stamp(sysctlBoot) ?? "?",
                        "derivedFromUptime": ProbeEnv.stamp(derivedBoot) ?? "?",
                        "disagreementSeconds": DeviceProbeFmt.f3(delta),
                        "uptimeSeconds": DeviceProbeFmt.f3(uptime)]
            ))
            items.append(rebootLedger(bootTime: sysctlBoot))
        } else {
            items.append(ProbeItem(
                "device.bootTime", "Boot timestamp", .partial,
                value: ProbeEnv.stamp(derivedBoot) ?? "?",
                detail: "sysctl kern.boottime failed, so only the derived value (now − systemUptime) "
                      + "is available. It drifts on every read and is a weak reboot-log anchor.",
                extra: ["derivedFromUptime": ProbeEnv.stamp(derivedBoot) ?? "?"]
            ))
        }

        items.append(ProbeItem(
            "device.hostEnvironment", "Host environment", .ok,
            value: pi.isiOSAppOnMac ? "iOS app on Mac"
                 : (pi.isMacCatalystApp ? "Mac Catalyst" : "native iOS"),
            detail: "Both flags matter to a collector: on a Mac host, motion, battery-state and "
                  + "proximity semantics all change, and the telemetry should be tagged so those "
                  + "runs are not pooled with real-phone runs.",
            extra: ["isiOSAppOnMac": DeviceProbeFmt.bool(pi.isiOSAppOnMac),
                    "isMacCatalystApp": DeviceProbeFmt.bool(pi.isMacCatalystApp),
                    "isSimulator": DeviceProbeFmt.bool(ProbeEnv.isSimulator),
                    "operatingSystemVersion": pi.operatingSystemVersionString]
        ))

        return items
    }

    /// Persists the boot instant so successive runs accumulate a real reboot log.
    private func rebootLedger(bootTime: Date) -> ProbeItem {
        let epoch = bootTime.timeIntervalSince1970
        let prior = DeviceProbeLedger.double(DeviceProbeLedger.kBootAnchor)
        var log = DeviceProbeLedger.strings(DeviceProbeLedger.kRebootLog)
        var reboots = DeviceProbeLedger.count(DeviceProbeLedger.kRebootCount)
        var note: String
        var status: ProbeStatus = .ok

        if let prior {
            if abs(epoch - prior) > 5 {
                reboots += 1
                DeviceProbeLedger.bump(DeviceProbeLedger.kRebootCount)
                log.append(ProbeEnv.iso.string(from: bootTime))
                if log.count > 40 { log = Array(log.suffix(40)) }
                DeviceProbeLedger.setStrings(DeviceProbeLedger.kRebootLog, log)
                DeviceProbeLedger.setDouble(DeviceProbeLedger.kBootAnchor, epoch)
                note = "REBOOT DETECTED since the last probe run. The stored anchor moved by "
                     + "\(DeviceProbeFmt.f2(epoch - prior))s."
            } else {
                note = "Same boot session as the last probe run (anchor moved "
                     + "\(DeviceProbeFmt.f2(epoch - prior))s, inside the 5s NTP-jitter tolerance)."
            }
        } else {
            DeviceProbeLedger.setDouble(DeviceProbeLedger.kBootAnchor, epoch)
            log = [ProbeEnv.iso.string(from: bootTime)]
            DeviceProbeLedger.setStrings(DeviceProbeLedger.kRebootLog, log)
            note = "First observation — the anchor is now stored, so the NEXT run can detect a reboot."
            status = .empty
        }

        return ProbeItem(
            "device.rebootLog", "Reboot log (cross-run)", status,
            value: "\(reboots) reboot(s) observed across \(log.count) recorded boot(s)",
            detail: note + " Reboots are only detected between probe runs — this is a sampled log, "
                  + "not a continuous one, and it will miss a reboot that happens between two runs "
                  + "if a third reboot has already overwritten the anchor. A background-scheduled "
                  + "collector sampling kern.boottime on every wakeup would close that gap.",
            extra: ["rebootCount": ProbeEnv.int(reboots),
                    "currentBoot": ProbeEnv.iso.string(from: bootTime),
                    "recordedBoots": log.suffix(10).joined(separator: ", ")]
        )
    }
}

// MARK: - 6. Screen

extension DeviceProbe {

    @MainActor
    private func currentWindowScene() -> UIWindowScene? {
        for scene in UIApplication.shared.connectedScenes {
            if let ws = scene as? UIWindowScene { return ws }
        }
        return nil
    }

    @MainActor
    func readScreen() async -> [ProbeItem] {
        var items: [ProbeItem] = []
        let scene = currentWindowScene()

        // UIScreen.main is DEPRECATED as of iOS 26 in favour of reaching the
        // screen through a window scene. We use the scene path and keep main
        // only as a last-resort fallback, so the collector inherits the modern
        // path. Recorded because it is a real constraint on the collector.
        let screen: UIScreen = scene?.screen ?? UIScreen.main
        let usedFallback = (scene == nil)

        items.append(ProbeItem(
            "device.screen.brightness", "Screen brightness", .ok,
            value: DeviceProbeFmt.f3(Double(screen.brightness)),
            detail: "0.0–1.0. This probe READS ONLY and never writes it: assigning to "
                  + "UIScreen.brightness silently turns Auto-Brightness off in Settings and would "
                  + "permanently degrade the device we are measuring. With Auto-Brightness on, this "
                  + "value tracks ambient light and is the best public proxy for a light sensor "
                  + "(the real ALS is SensorKit-only — see AmbientProbe).",
            extra: ["raw": DeviceProbeFmt.f3(Double(screen.brightness))]
        ))

        items.append(ProbeItem(
            "device.screen.geometry", "Screen geometry", .ok,
            value: "\(Int(screen.bounds.width))×\(Int(screen.bounds.height)) pt @\(DeviceProbeFmt.f2(Double(screen.nativeScale)))x",
            detail: usedFallback
                ? "Read via the DEPRECATED UIScreen.main because no UIWindowScene was connected. "
                + "UIScreen.main is deprecated in iOS 26.0 — the collector must reach the screen "
                + "through view.window.windowScene.screen, or use trait-collection equivalents."
                : "Read through the connected UIWindowScene, which is the iOS 26 supported path — "
                + "UIScreen.main is deprecated in iOS 26.0. nativeScale can differ from scale on "
                + "devices that render at one resolution and downsample to the panel (e.g. Plus/Max "
                + "models), so both are recorded.",
            extra: ["boundsPt": "\(DeviceProbeFmt.f2(Double(screen.bounds.width)))×\(DeviceProbeFmt.f2(Double(screen.bounds.height)))",
                    "nativeBoundsPx": "\(DeviceProbeFmt.f2(Double(screen.nativeBounds.width)))×\(DeviceProbeFmt.f2(Double(screen.nativeBounds.height)))",
                    "scale": DeviceProbeFmt.f2(Double(screen.scale)),
                    "nativeScale": DeviceProbeFmt.f2(Double(screen.nativeScale)),
                    "traitDisplayScale": DeviceProbeFmt.f2(Double(screen.traitCollection.displayScale)),
                    "usedDeprecatedUIScreenMain": DeviceProbeFmt.bool(usedFallback)]
        ))

        items.append(ProbeItem(
            "device.screen.refreshRate", "Maximum refresh rate", .ok,
            value: "\(screen.maximumFramesPerSecond) Hz",
            detail: "maximumFramesPerSecond. 120 indicates a ProMotion panel, which also means the "
                  + "display can drop to 10Hz or 1Hz when idle — relevant if the collector ever "
                  + "infers 'screen active' from frame callbacks."
        ))

        // isCaptured is the rarely-used one and it is genuinely valuable: it is
        // true for screen recording, AirPlay mirroring, and QuickTime capture.
        let captured = screen.isCaptured
        items.append(ProbeItem(
            "device.screen.isCaptured", "Screen being captured", captured ? .ok : .empty,
            value: DeviceProbeFmt.bool(captured),
            detail: "UIScreen.isCaptured — true while the screen is being recorded, mirrored via "
                  + "AirPlay, or captured over USB. Pairs with UIScreen.capturedDidChangeNotification "
                  + "(armed by this probe's ledger). This is one of the few public signals that "
                  + "reveals a device-level user action rather than an app-level one. False right "
                  + "now simply means nothing is recording during the probe.",
            extra: ["UIScreen.capturedDidChangeNotification":
                        UIScreen.capturedDidChangeNotification.rawValue,
                    "capturedChangeCountSinceArmed":
                        ProbeEnv.int(DeviceProbeLedger.count(DeviceProbeLedger.kCaptured)),
                    "lastCapturedChange":
                        DeviceProbeLedger.string(DeviceProbeLedger.kCapturedLast) ?? "never"]
        ))

        if let scene {
            items.append(ProbeItem(
                "device.screen.scene", "Window scene", .ok,
                value: "\(DeviceProbeFmt.interfaceOrientation(scene.interfaceOrientation)), \(scene.traitCollection.userInterfaceStyle == .dark ? "dark" : "light")",
                detail: "Scene-level state. userInterfaceStyle is a genuine daily-rhythm signal when "
                      + "the user runs Automatic appearance, because it flips at local sunset.",
                extra: ["interfaceOrientation": DeviceProbeFmt.interfaceOrientation(scene.interfaceOrientation),
                        "userInterfaceStyle": scene.traitCollection.userInterfaceStyle == .dark ? "dark" : "light",
                        "sizeClassH": "\(scene.traitCollection.horizontalSizeClass.rawValue)",
                        "sizeClassV": "\(scene.traitCollection.verticalSizeClass.rawValue)"]
            ))
        }

        return items
    }
}

// MARK: - 7. Output volume

extension DeviceProbe {

    func readVolume() -> [ProbeItem] {
        var items: [ProbeItem] = []
        let s = AVAudioSession.sharedInstance()
        let priorCategory = s.category
        var activationError: String?

        // outputVolume reads 0.0 until the session has been activated at least
        // once in this process. .ambient + .mixWithOthers is the only safe
        // combination here: it will not stop the user's music and will not steal
        // the route from AmbientProbe, which ran earlier and held the mic.
        // .ambient is used with NO options on purpose: it already mixes with
        // other audio and obeys the ringer switch, and passing .mixWithOthers
        // (which is only documented as valid for playback/playAndRecord/
        // multiRoute) can make setCategory throw for no benefit.
        do {
            try s.setCategory(.ambient)
            try s.setActive(true)
        } catch {
            activationError = error.localizedDescription
        }

        let volume = s.outputVolume
        let route = s.currentRoute.outputs.map { "\($0.portName) [\($0.portType.rawValue)]" }

        if let activationError {
            items.append(ProbeItem(
                "device.volume", "Output volume", .partial,
                value: DeviceProbeFmt.f3(Double(volume)),
                detail: "AVAudioSession activation failed (\(activationError)), so this reading may "
                      + "be the 0.0 default rather than the real hardware volume. The value is "
                      + "reported anyway because a nonzero result is still trustworthy.",
                extra: ["raw": DeviceProbeFmt.f3(Double(volume)),
                        "activationError": activationError]
            ))
        } else {
            items.append(ProbeItem(
                "device.volume", "Output volume", .ok,
                value: DeviceProbeFmt.pct(volume),
                detail: """
                AVAudioSession.outputVolume, 0.0–1.0, quantised to 1/16 steps by the hardware \
                volume buttons.

                KVO: this property IS key-value observable on the "outputVolume" key path, and \
                that is the ONLY supported way to see volume-button presses. It is worth having \
                because it is a live human-interaction signal that survives the screen being off \
                (the user pressing volume while the phone is in a pocket).

                Two caveats for the collector: the session must stay activated for KVO to keep \
                delivering, and observing volume is per-route — plugging in AirPods swaps to a \
                separate volume scale and fires a change that is not a user action.
                """,
                extra: ["raw": DeviceProbeFmt.f3(Double(volume)),
                        "kvoKeyPath": "outputVolume",
                        "categoryBefore": priorCategory.rawValue,
                        "categoryUsed": AVAudioSession.Category.ambient.rawValue,
                        "outputRoute": route.isEmpty ? "none" : route.joined(separator: ", "),
                        "outputCount": ProbeEnv.int(s.currentRoute.outputs.count)]
            ))
        }

        // Restore. Deactivating with .notifyOthersOnDeactivation lets any app we
        // ducked resume immediately.
        try? s.setActive(false, options: [.notifyOthersOnDeactivation])
        try? s.setCategory(priorCategory)

        return items
    }
}

// MARK: - 8. Orientation & proximity

extension DeviceProbe {

    @MainActor
    func readOrientationAndProximity() async -> [ProbeItem] {
        var items: [ProbeItem] = []
        let dev = UIDevice.current

        // --- Orientation ----------------------------------------------------
        let wasGenerating = dev.isGeneratingDeviceOrientationNotifications
        if !wasGenerating { dev.beginGeneratingDeviceOrientationNotifications() }

        var orientation = dev.orientation
        var polls = 0
        while orientation == .unknown && polls < DeviceProbe.settlePollCount {
            try? await Task.sleep(nanoseconds: DeviceProbe.settlePollNanos)
            orientation = dev.orientation
            polls += 1
        }
        let settleMs = polls * 50
        let interfaceOrientation = currentWindowScene()?.interfaceOrientation ?? .unknown

        items.append(ProbeItem(
            "device.orientation", "Device orientation",
            orientation == .unknown ? .partial : .ok,
            value: "device \(DeviceProbeFmt.deviceOrientation(orientation)) / interface \(DeviceProbeFmt.interfaceOrientation(interfaceOrientation))",
            detail: """
            Two different things, and the gap between them is the finding.

            UIDevice.orientation is the PHYSICAL attitude and needs accelerometer generation \
            switched on; it settled after \(settleMs)ms of polling. It reports faceUp/faceDown, \
            which the interface orientation cannot — that makes it the useful one for telemetry \
            (a phone lying face-down on a table is a real behavioural state).

            UIWindowScene.interfaceOrientation is what the UI is actually drawn at. It is always \
            valid and is clamped by the app's supported orientations, so it will never report \
            faceUp and will disagree whenever rotation lock is on.

            Generation is refcounted, so this probe only ends it if it started it \
            (was already generating: \(DeviceProbeFmt.bool(wasGenerating))).
            """,
            extra: ["deviceOrientation": DeviceProbeFmt.deviceOrientation(orientation),
                    "deviceOrientationRaw": ProbeEnv.int(orientation.rawValue),
                    "interfaceOrientation": DeviceProbeFmt.interfaceOrientation(interfaceOrientation),
                    "isFlat": DeviceProbeFmt.bool(orientation.isFlat),
                    "isPortrait": DeviceProbeFmt.bool(orientation.isPortrait),
                    "isLandscape": DeviceProbeFmt.bool(orientation.isLandscape),
                    "settleMs": ProbeEnv.int(settleMs),
                    "wasAlreadyGenerating": DeviceProbeFmt.bool(wasGenerating),
                    "UIDevice.orientationDidChangeNotification":
                        UIDevice.orientationDidChangeNotification.rawValue]
        ))

        if !wasGenerating { dev.endGeneratingDeviceOrientationNotifications() }

        // --- Proximity ------------------------------------------------------
        // The readback IS the capability test: on hardware without the sensor
        // (or in the Simulator) the property refuses to latch to true.
        let wasProximity = dev.isProximityMonitoringEnabled
        dev.isProximityMonitoringEnabled = true
        let latched = dev.isProximityMonitoringEnabled
        let proximityState = dev.proximityState
        dev.isProximityMonitoringEnabled = wasProximity

        items.append(ProbeItem(
            "device.proximity", "Proximity sensor", latched ? .ok : .unavailable,
            value: DeviceProbeFmt.proximity(latched, proximityState),
            detail: latched
                ? "isProximityMonitoringEnabled latched true, so the sensor exists. Read and then "
                + "immediately disabled: while monitoring is on, iOS BLANKS THE DISPLAY whenever "
                + "the sensor reads near, which would black out the probe mid-run. A collector can "
                + "use this as a 'phone held to ear' / 'in pocket' signal, but only in short "
                + "windows for exactly that reason. Change notification: "
                + UIDevice.proximityStateDidChangeNotification.rawValue
                : "Setting isProximityMonitoringEnabled = true did not latch — the property read "
                + "back false, which means this hardware/environment has no usable proximity "
                + "sensor (expected in the Simulator and on iPad).",
            extra: ["latched": DeviceProbeFmt.bool(latched),
                    "proximityState": DeviceProbeFmt.bool(proximityState),
                    "wasAlreadyEnabled": DeviceProbeFmt.bool(wasProximity),
                    "UIDevice.proximityStateDidChangeNotification":
                        UIDevice.proximityStateDidChangeNotification.rawValue]
        ))

        return items
    }
}

// MARK: - 9. Locale & time

extension DeviceProbe {

    func readLocaleAndTime() -> [ProbeItem] {
        var items: [ProbeItem] = []
        let loc = Locale.current
        let cal = Calendar.current
        let tz = TimeZone.current
        let now = Date()

        items.append(ProbeItem(
            "device.locale", "Locale", .ok,
            value: loc.identifier,
            detail: "Locale identifier plus calendar and measurement system. measurementSystem is "
                  + "rendered with String(describing:) rather than a member accessor, because the "
                  + "exact property surface of Locale.MeasurementSystem could not be verified "
                  + "against developer.apple.com without a compiler to hand.",
            extra: ["identifier": loc.identifier,
                    "calendar": "\(cal.identifier)",
                    "measurementSystem": "\(loc.measurementSystem)",
                    "localizedName": loc.localizedString(forIdentifier: loc.identifier) ?? "?",
                    "preferredLanguages": Locale.preferredLanguages.prefix(4).joined(separator: ", ")]
        ))

        let offset = tz.secondsFromGMT(for: now)
        let dst = tz.isDaylightSavingTime(for: now)
        var tzExtra: [String: String] = [
            "identifier": tz.identifier,
            "secondsFromGMT": ProbeEnv.int(offset),
            "hoursFromGMT": DeviceProbeFmt.f2(Double(offset) / 3600),
            "abbreviation": tz.abbreviation(for: now) ?? "?",
            "isDaylightSavingTime": DeviceProbeFmt.bool(dst),
            "daylightSavingOffset": DeviceProbeFmt.f2(tz.daylightSavingTimeOffset(for: now)),
            "sampledAt": ProbeEnv.iso.string(from: now)
        ]
        if let next = tz.nextDaylightSavingTimeTransition(after: now) {
            tzExtra["nextDSTTransition"] = ProbeEnv.iso.string(from: next)
        }

        items.append(ProbeItem(
            "device.timezone", "Time zone", .ok,
            value: "\(tz.identifier) (UTC\(offset >= 0 ? "+" : "")\(DeviceProbeFmt.f2(Double(offset) / 3600)))",
            detail: """
            The time zone is a TRAVEL DETECTOR, and a good one: it changes without any location \
            permission, it changes while the app is in the background, and it survives a cold \
            launch. A collector that logs nothing but time-zone transitions still reconstructs \
            every trip across a zone boundary at zero permission cost.

            The system posts a notification named "NSSystemTimeZoneDidChangeNotification" when this \
            changes. That string is reported as a LITERAL and was not compile-verified — unlike the \
            other notification names in this section, the exact Swift symbol spelling could not be \
            confirmed against developer.apple.com at authoring time. Confirm it before the collector \
            depends on it; the underlying notification name itself is well established.
            """,
            extra: tzExtra
        ))

        return items
    }
}

// MARK: - 10. Accessibility settings fingerprint

extension DeviceProbe {

    @MainActor
    func readAccessibility() async -> [ProbeItem] {
        var items: [ProbeItem] = []

        // Ordered deliberately — the order defines the fingerprint hash, so
        // never reorder this array without accepting that every stored
        // fingerprint becomes incomparable.
        let flags: [(String, Bool)] = [
            ("isReduceMotionEnabled",         UIAccessibility.isReduceMotionEnabled),
            ("prefersCrossFadeTransitions",   UIAccessibility.prefersCrossFadeTransitions),
            ("isReduceTransparencyEnabled",   UIAccessibility.isReduceTransparencyEnabled),
            ("isBoldTextEnabled",             UIAccessibility.isBoldTextEnabled),
            ("isDarkerSystemColorsEnabled",   UIAccessibility.isDarkerSystemColorsEnabled),
            ("isVoiceOverRunning",            UIAccessibility.isVoiceOverRunning),
            ("isSwitchControlRunning",        UIAccessibility.isSwitchControlRunning),
            ("isOnOffSwitchLabelsEnabled",    UIAccessibility.isOnOffSwitchLabelsEnabled),
            ("isAssistiveTouchRunning",       UIAccessibility.isAssistiveTouchRunning),
            ("isGuidedAccessEnabled",         UIAccessibility.isGuidedAccessEnabled),
            ("isGrayscaleEnabled",            UIAccessibility.isGrayscaleEnabled),
            ("isInvertColorsEnabled",         UIAccessibility.isInvertColorsEnabled),
            ("shouldDifferentiateWithoutColor", UIAccessibility.shouldDifferentiateWithoutColor),
            ("isMonoAudioEnabled",            UIAccessibility.isMonoAudioEnabled),
            ("isClosedCaptioningEnabled",     UIAccessibility.isClosedCaptioningEnabled),
            ("isVideoAutoplayEnabled",        UIAccessibility.isVideoAutoplayEnabled),
            ("isSpeakScreenEnabled",          UIAccessibility.isSpeakScreenEnabled),
            ("isSpeakSelectionEnabled",       UIAccessibility.isSpeakSelectionEnabled),
            ("isShakeToUndoEnabled",          UIAccessibility.isShakeToUndoEnabled)
        ]

        let contentSize = UIApplication.shared.preferredContentSizeCategory
        let enabledFlags = flags.filter { $0.1 }.map { $0.0 }

        var extra: [String: String] = [:]
        for (name, value) in flags { extra[name] = DeviceProbeFmt.bool(value) }
        extra["preferredContentSizeCategory"] = contentSize.rawValue
        extra["isAccessibilityCategory"] = DeviceProbeFmt.bool(contentSize.isAccessibilityCategory)
        extra["enabledCount"] = ProbeEnv.int(enabledFlags.count)

        // Stable across launches — Swift's own Hasher is seeded per process and
        // would produce a different value every run, which is useless here.
        let fingerprintSource = flags.map { "\($0.0)=\($0.1 ? 1 : 0)" }.joined(separator: ";")
            + ";contentSize=\(contentSize.rawValue)"
        let fingerprint = DeviceProbeFmt.stableHash(fingerprintSource)
        extra["fingerprint"] = fingerprint

        items.append(ProbeItem(
            "device.accessibility", "Accessibility settings fingerprint",
            enabledFlags.isEmpty ? .empty : .ok,
            value: enabledFlags.isEmpty
                ? "all defaults (fingerprint \(fingerprint))"
                : "\(enabledFlags.count) enabled (fingerprint \(fingerprint))",
            detail: """
            \(flags.count) booleans plus the Dynamic Type size, read with no permission prompt of \
            any kind. Two distinct uses, and it is worth being honest that they pull in opposite \
            directions:

            • AS A REAL SIGNAL. These are the user's own accessibility needs. Reduce Motion and \
            Bold Text correlate with eye strain and fatigue; a Dynamic Type size that drifts \
            upward over months is a genuine longitudinal health observation that no health API \
            exposes. Currently \(contentSize.rawValue).

            • AS A FINGERPRINT. The vector is high-entropy and almost perfectly stable, which is \
            exactly why it is a classic cross-app device-fingerprinting surface. Recorded here as \
            one FNV-1a hash so change detection is a single string compare, and because storing \
            the digest rather than the vector is the more defensible thing to keep in a database.

            Currently enabled: \(enabledFlags.isEmpty ? "none" : enabledFlags.joined(separator: ", ")).

            OMITTED: UIAccessibility.buttonShapesEnabled, which is documented as deprecated on the \
            current SDK and was not worth a deprecation warning for one extra boolean.

            Change tracking: UIAccessibility posts a separate *DidChangeNotification per setting \
            (e.g. UIAccessibility.reduceMotionStatusDidChangeNotification) plus \
            \(UIContentSizeCategory.didChangeNotification.rawValue) for Dynamic Type.
            """,
            extra: extra
        ))

        return items
    }
}

// MARK: - 11. Lock / unlock detection

extension DeviceProbe {

    @MainActor
    func readLockState() async -> [ProbeItem] {
        var items: [ProbeItem] = []

        // --- (a) The supported route: protected data availability -----------
        let protectedAvailable = UIApplication.shared.isProtectedDataAvailable
        items.append(ProbeItem(
            "device.lock.protectedData", "Protected data availability", .ok,
            value: protectedAvailable ? "available (device unlocked since boot)" : "unavailable (locked)",
            detail: """
            The only SUPPORTED public proxy for lock state, and it is a weak one. \
            isProtectedDataAvailable becomes true at the first unlock after boot and, on most \
            configurations, STAYS true through subsequent locks — so it reliably detects \
            "has never been unlocked since boot" and unreliably detects "is locked right now".

            Both notifications compile against this SDK and are armed by this probe's ledger, so \
            the counts below are measured, not assumed. If the unavailable-count stays at 0 across \
            a run where you demonstrably locked the phone, that confirms the notification tracks \
            data-protection class availability rather than the lock switch.
            """,
            extra: [
                "isProtectedDataAvailable": DeviceProbeFmt.bool(protectedAvailable),
                "UIApplication.protectedDataDidBecomeAvailableNotification":
                    UIApplication.protectedDataDidBecomeAvailableNotification.rawValue,
                "UIApplication.protectedDataWillBecomeUnavailableNotification":
                    UIApplication.protectedDataWillBecomeUnavailableNotification.rawValue,
                "becameAvailableCountSinceArmed":
                    ProbeEnv.int(DeviceProbeLedger.count(DeviceProbeLedger.kProtectedAvail)),
                "becameUnavailableCountSinceArmed":
                    ProbeEnv.int(DeviceProbeLedger.count(DeviceProbeLedger.kProtectedUnavail)),
                "lastProtectedDataEvent":
                    DeviceProbeLedger.string(DeviceProbeLedger.kProtectedLast) ?? "never",
                "armedAt": DeviceProbeLedger.string(DeviceProbeLedger.kArmedAt) ?? "never"
            ]
        ))

        // --- (b) The unsupported-but-public route: Darwin notifications -----
        //
        // notify_register_check RETURNS a status code, which CFNotificationCenter
        // does not. That return value is the only synchronous ground truth
        // available on whether these names are still registrable on iOS 26.
        var lockStateToken: Int32 = 0
        var lockCompleteToken: Int32 = 0
        var lockStateValue: UInt64 = 0
        var lockStateGetStatus: UInt32 = 0

        let regStatus = DeviceProbeLedger.lockStateName.withCString { cs in
            notify_register_check(cs, &lockStateToken)
        }
        // 0 == NOTIFY_STATUS_OK. The constant is a #define in notify.h and is not
        // exposed to Swift, so we compare against the literal and record the raw
        // number rather than referencing a symbol that may not exist.
        if regStatus == 0 {
            lockStateGetStatus = notify_get_state(lockStateToken, &lockStateValue)
        }

        let regCompleteStatus = DeviceProbeLedger.lockCompleteName.withCString { cs in
            notify_register_check(cs, &lockCompleteToken)
        }

        let lockStateCount = DeviceProbeLedger.count(DeviceProbeLedger.kLockState)
        let lockCompleteCount = DeviceProbeLedger.count(DeviceProbeLedger.kLockComplete)
        let observedAny = (lockStateCount + lockCompleteCount) > 0

        var darwinExtra: [String: String] = [
            "lockstateName": DeviceProbeLedger.lockStateName,
            "lockcompleteName": DeviceProbeLedger.lockCompleteName,
            "notify_register_check.lockstate.status": String(regStatus),
            "notify_register_check.lockcomplete.status": String(regCompleteStatus),
            "notify_get_state.status": String(lockStateGetStatus),
            "notify_get_state.value": String(lockStateValue),
            "lockstateFireCount": ProbeEnv.int(lockStateCount),
            "lockcompleteFireCount": ProbeEnv.int(lockCompleteCount),
            "armedAt": DeviceProbeLedger.string(DeviceProbeLedger.kArmedAt) ?? "never",
            "statusOkMeans": "0"
        ]
        if let last = DeviceProbeLedger.string(DeviceProbeLedger.kDarwinLastFired) {
            darwinExtra["lastDarwinNotification"] = last
        }

        // Registration succeeding is necessary but not sufficient; only a fire
        // count proves delivery. Status reflects exactly that distinction.
        let darwinStatus: ProbeStatus
        let darwinValue: String
        if observedAny {
            darwinStatus = .ok
            darwinValue = "CONFIRMED FIRING — lockstate ×\(lockStateCount), lockcomplete ×\(lockCompleteCount)"
        } else if regStatus == 0 {
            darwinStatus = .empty
            darwinValue = "registration OK (status 0), no fires observed yet"
        } else {
            darwinStatus = .unavailable
            darwinValue = "registration REFUSED (status \(regStatus))"
        }

        items.append(ProbeItem(
            "device.lock.darwin", "Springboard lock Darwin notifications", darwinStatus,
            value: darwinValue,
            detail: """
            WHAT THIS IS, PRECISELY. CFNotificationCenterGetDarwinNotifyCenter(), \
            notify_register_check() and notify_get_state() are all PUBLIC, exported, documented C \
            API (notify(3)). What is not public is the two NOTIFICATION NAMES — \
            "com.apple.springboard.lockstate" and "com.apple.springboard.lockcomplete" are \
            undocumented system notification names posted by SpringBoard and do not appear in \
            notify_keys.h. No private framework is dlopened and no unexported symbol is called; \
            this is public API observing an undocumented string.

            APP REVIEW WOULD REJECT THIS. Apple has rejected apps for exactly this since 2017 with \
            "Unsupported operation - Apps are not allowed to listen to device lock notifications". \
            That is acceptable here and only here, because this app is SIDELOADED for its own \
            owner and never goes near the App Store.

            WHAT WEB SEARCH COULD AND COULD NOT SETTLE. Every current source confirms the App \
            Review policy. None confirms whether the sandbox technically BLOCKS delivery on iOS 26 \
            — the two claims are constantly conflated, and Apple forum threads on the subject \
            predate iOS 17. So this probe measures it instead of citing it.

            HOW IT MEASURES. Two independent mechanisms:
              1. notify_register_check() returns a status code synchronously (0 = OK). Registration \
            status here: lockstate=\(regStatus), lockcomplete=\(regCompleteStatus). \
            notify_get_state() returned status \(lockStateGetStatus) with value \(lockStateValue) \
            (historically 1 = locked, 0 = unlocked).
              2. A CFNotificationCenter Darwin observer armed by this probe's ledger, with counters \
            persisted in UserDefaults across launches.

            THE HARD LIMIT, stated plainly: this only works WHILE THE PROCESS IS ALIVE. iOS \
            suspends and eventually terminates a backgrounded app, and nothing is delivered or \
            counted while it is dead. Even if these notifications fire perfectly, they cannot give \
            a complete lock/unlock log — only a log covering the windows in which the collector \
            happened to be running.

            TO SETTLE IT: leave this app in the foreground, lock the phone with the side button, \
            unlock it, then re-run the probe and read lockstateFireCount below. Nonzero proves \
            delivery on this OS build; zero after a demonstrated lock proves the sandbox now \
            filters it.
            """,
            extra: darwinExtra
        ))

        // Release the check tokens; the persistent CF observer is what stays armed.
        if regStatus == 0 { _ = notify_cancel(lockStateToken) }
        if regCompleteStatus == 0 { _ = notify_cancel(lockCompleteToken) }

        return items
    }
}

// MARK: - 12. Screenshot detection

extension DeviceProbe {

    @MainActor
    func readScreenshotDetection() async -> [ProbeItem] {
        let count = DeviceProbeLedger.count(DeviceProbeLedger.kScreenshot)
        let capturedCount = DeviceProbeLedger.count(DeviceProbeLedger.kCaptured)

        return [ProbeItem(
            "device.screenshot", "Screenshot & capture detection",
            count > 0 ? .ok : .empty,
            value: count > 0
                ? "CONFIRMED FIRING — \(count) screenshot(s) observed"
                : "armed, none observed yet",
            detail: """
            Both symbols compile against this SDK and both are armed by this probe's ledger.

            UIApplication.userDidTakeScreenshotNotification fires AFTER the screenshot is taken. \
            There is no public API to prevent one, to see its contents, or to detect a screenshot \
            taken while this app is backgrounded — it is delivered to the foreground app only, so \
            for a telemetry collector it measures "screenshots of THIS app", not "screenshots the \
            user took". That distinction matters and is easy to get wrong.

            UIScreen.capturedDidChangeNotification is the broader and more useful one: it fires on \
            screen recording start/stop and on AirPlay mirroring, and unlike the screenshot \
            notification the accompanying UIScreen.isCaptured state can be READ at any moment \
            rather than only observed at the instant of change.

            TO CONFIRM: take a screenshot while this app is in the foreground, then re-run the \
            probe and read screenshotCount below.
            """,
            extra: [
                "UIApplication.userDidTakeScreenshotNotification":
                    UIApplication.userDidTakeScreenshotNotification.rawValue,
                "UIScreen.capturedDidChangeNotification":
                    UIScreen.capturedDidChangeNotification.rawValue,
                "screenshotCount": ProbeEnv.int(count),
                "lastScreenshot": DeviceProbeLedger.string(DeviceProbeLedger.kScreenshotLast) ?? "never",
                "capturedChangeCount": ProbeEnv.int(capturedCount),
                "lastCapturedChange": DeviceProbeLedger.string(DeviceProbeLedger.kCapturedLast) ?? "never",
                "armedAt": DeviceProbeLedger.string(DeviceProbeLedger.kArmedAt) ?? "never"
            ]
        )]
    }
}

// MARK: - 13. User notifications

struct DeviceProbeAuthResult {
    var granted = false
    var error: String?
    var timedOut = false
}

extension DeviceProbe {

    func readNotifications() async -> [ProbeItem] {
        var items: [ProbeItem] = []
        let center = UNUserNotificationCenter.current()

        // Runs strictly serially with everything else — iOS presents one system
        // permission sheet at a time and racing them drops prompts silently.
        // A human has to tap, so the deadline is generous but still well inside
        // the runner's 180s per-probe budget.
        let auth: DeviceProbeAuthResult = await DeviceProbeAwait.once(
            timeout: DeviceProbe.notificationPromptTimeout,
            timeoutValue: DeviceProbeAuthResult(granted: false, error: nil, timedOut: true)
        ) { done in
            center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
                done(DeviceProbeAuthResult(granted: granted,
                                           error: error?.localizedDescription,
                                           timedOut: false))
            }
        }

        if auth.timedOut {
            items.append(ProbeItem(
                "device.notifications.auth", "Notification authorization", .notDetermined,
                value: "prompt not answered within \(Int(DeviceProbe.notificationPromptTimeout))s",
                detail: "requestAuthorization never called back. Either the system sheet was left "
                      + "on screen or it was never presented. Not an error — re-run the probe and "
                      + "answer the prompt."
            ))
        } else if let err = auth.error {
            items.append(ProbeItem(
                "device.notifications.auth", "Notification authorization", .error,
                value: "request failed",
                detail: err
            ))
        } else {
            items.append(ProbeItem(
                "device.notifications.auth", "Notification authorization",
                auth.granted ? .ok : .denied,
                value: auth.granted ? "granted" : "not granted",
                detail: "requestAuthorization([.alert, .badge, .sound]). The REQUEST outcome and "
                      + "the resulting SETTINGS are reported separately below, because they "
                      + "routinely disagree: a user can grant here and then disable individual "
                      + "settings in Settings.app, and the request will still report granted on "
                      + "subsequent calls.",
                extra: ["granted": DeviceProbeFmt.bool(auth.granted),
                        "optionsRequested": "alert, badge, sound"]
            ))
        }

        // --- Settings, read verbatim ----------------------------------------
        let settings: UNNotificationSettings? = await DeviceProbeAwait.once(
            timeout: 15, timeoutValue: UNNotificationSettings?.none
        ) { done in
            center.getNotificationSettings { s in done(s) }
        }

        if let s = settings {
            var extra: [String: String] = [
                "authorizationStatus": DeviceProbeFmt.unAuthStatus(s.authorizationStatus),
                "alertSetting": DeviceProbeFmt.unSetting(s.alertSetting),
                "badgeSetting": DeviceProbeFmt.unSetting(s.badgeSetting),
                "soundSetting": DeviceProbeFmt.unSetting(s.soundSetting),
                "criticalAlertSetting": DeviceProbeFmt.unSetting(s.criticalAlertSetting),
                "timeSensitiveSetting": DeviceProbeFmt.unSetting(s.timeSensitiveSetting),
                "scheduledDeliverySetting": DeviceProbeFmt.unSetting(s.scheduledDeliverySetting),
                "announcementSetting": DeviceProbeFmt.unSetting(s.announcementSetting),
                "notificationCenterSetting": DeviceProbeFmt.unSetting(s.notificationCenterSetting),
                "lockScreenSetting": DeviceProbeFmt.unSetting(s.lockScreenSetting),
                "carPlaySetting": DeviceProbeFmt.unSetting(s.carPlaySetting),
                "alertStyle": DeviceProbeFmt.unAlertStyle(s.alertStyle),
                "showPreviewsSetting": DeviceProbeFmt.unShowPreviews(s.showPreviewsSetting),
                "providesAppNotificationSettings": DeviceProbeFmt.bool(s.providesAppNotificationSettings)
            ]
            extra["authorizationStatusRaw"] = ProbeEnv.int(s.authorizationStatus.rawValue)

            items.append(ProbeItem(
                "device.notifications.settings", "Notification settings", .ok,
                value: DeviceProbeFmt.unAuthStatus(s.authorizationStatus),
                detail: """
                Fourteen of the fifteen documented properties of UNNotificationSettings, read \
                verbatim. (`directMessagesSetting` is omitted: it is documented on the current \
                SDK but its introducing iOS version could not be confirmed, and referencing a \
                post-iOS-17 symbol without an availability guard would be a compile error against \
                this project's 17.0 deployment target.) Two of them are entitlement-gated and \
                their values are the real finding:

                • criticalAlertSetting = \(DeviceProbeFmt.unSetting(s.criticalAlertSetting)) — \
                requires com.apple.developer.usernotifications.critical-alerts, which needs a \
                special Apple request beyond the $99 program. `notSupported` here is the expected \
                answer and confirms we cannot bypass silent mode.
                • timeSensitiveSetting = \(DeviceProbeFmt.unSetting(s.timeSensitiveSetting)) — \
                requires com.apple.developer.usernotifications.time-sensitive. This one matters, \
                because Time Sensitive is what lets a notification break through a Focus mode.

                scheduledDeliverySetting = \(DeviceProbeFmt.unSetting(s.scheduledDeliverySetting)) \
                reports whether the user has Scheduled Summary on, which delays delivery and would \
                distort any latency measurement built on notifications.
                """,
                extra: extra
            ))
        } else {
            items.append(ProbeItem(
                "device.notifications.settings", "Notification settings", .error,
                detail: "getNotificationSettings did not call back within 15s."
            ))
        }

        // --- Delivered notifications ----------------------------------------
        let delivered: Int? = await DeviceProbeAwait.once(
            timeout: 15, timeoutValue: Int?.none
        ) { done in
            center.getDeliveredNotifications { list in done(list.count) }
        }
        let pending: Int? = await DeviceProbeAwait.once(
            timeout: 15, timeoutValue: Int?.none
        ) { done in
            center.getPendingNotificationRequests { list in done(list.count) }
        }

        if let delivered {
            items.append(ProbeItem(
                "device.notifications.delivered", "Delivered notifications",
                delivered > 0 ? .ok : .empty,
                value: "\(delivered) in Notification Center",
                detail: """
                THIS APP ONLY. getDeliveredNotifications returns notifications delivered by THIS \
                app that are still in Notification Center. It is 0 here because a probe app has \
                never posted one.

                KILL THE IDEA NOW, because it is the single most commonly assumed iOS telemetry \
                capability and it does not exist: there is NO public API that reads other apps' \
                notifications. Not UNUserNotificationCenter, not a Notification Service Extension \
                (which only sees payloads addressed to its own app), not Focus filters, not \
                Screen Time. On iOS the only process that sees the full notification stream is \
                SpringBoard, and the only third-party surface that ever gets close is a paired \
                watchOS/companion accessory receiving forwarded notifications — which requires the \
                notification-forwarding path Apple reserves for accessories, not apps.

                What a collector CAN do instead: count and time-stamp its OWN notifications, and \
                use a Shortcuts personal automation as the event channel for anything else \
                (see IntentsProbe).
                """,
                extra: ["deliveredCount": ProbeEnv.int(delivered),
                        "pendingCount": pending.map { ProbeEnv.int($0) } ?? "?",
                        "scope": "this app only",
                        "otherAppsReadable": "false — no public API exists"]
            ))
        } else {
            items.append(ProbeItem(
                "device.notifications.delivered", "Delivered notifications", .error,
                detail: "getDeliveredNotifications did not call back within 15s."
            ))
        }

        return items
    }
}

// MARK: - 14. App lifecycle

extension DeviceProbe {

    @MainActor
    func readLifecycle() async -> [ProbeItem] {
        let state = UIApplication.shared.applicationState

        return [ProbeItem(
            "device.lifecycle", "App lifecycle state", .ok,
            value: DeviceProbeFmt.appState(state),
            detail: """
            Always `active` when read from a foreground probe run — the value is only interesting \
            to a background collector, where it distinguishes a real user open from a \
            BGTaskScheduler wakeup (see BackgroundProbe).

            LIFECYCLE AS AN ATTENTION PROXY. This is the cheapest usable engagement signal on iOS, \
            and its ceiling should be stated honestly. didBecomeActive/willResignActive bracket \
            every period the user is looking at THIS app; the elapsed time between them is real \
            attention data. But iOS gives an app no visibility into any other app's foreground \
            time — DeviceActivityReport is sandboxed and cannot exfiltrate what it renders — so \
            these notifications measure attention on this one app and nothing else.

            The counters below are measured by this probe's persistent ledger, so \
            didBecomeActiveCount is a genuine count of app-open events since arming (minus any \
            that occurred while the process was dead).
            """,
            extra: [
                "applicationState": DeviceProbeFmt.appState(state),
                "applicationStateRaw": ProbeEnv.int(state.rawValue),
                "UIApplication.didBecomeActiveNotification":
                    UIApplication.didBecomeActiveNotification.rawValue,
                "UIApplication.willResignActiveNotification":
                    UIApplication.willResignActiveNotification.rawValue,
                "UIApplication.didEnterBackgroundNotification":
                    UIApplication.didEnterBackgroundNotification.rawValue,
                "UIApplication.willEnterForegroundNotification":
                    UIApplication.willEnterForegroundNotification.rawValue,
                "UIApplication.willTerminateNotification":
                    UIApplication.willTerminateNotification.rawValue,
                "didBecomeActiveCount":
                    ProbeEnv.int(DeviceProbeLedger.count(DeviceProbeLedger.kDidBecomeActive)),
                "willResignActiveCount":
                    ProbeEnv.int(DeviceProbeLedger.count(DeviceProbeLedger.kWillResign)),
                "didEnterBackgroundCount":
                    ProbeEnv.int(DeviceProbeLedger.count(DeviceProbeLedger.kDidEnterBg)),
                "willEnterForegroundCount":
                    ProbeEnv.int(DeviceProbeLedger.count(DeviceProbeLedger.kWillEnterFg)),
                "armedAt": DeviceProbeLedger.string(DeviceProbeLedger.kArmedAt) ?? "never"
            ]
        )]
    }
}

// MARK: - 15. Pasteboard

extension DeviceProbe {

    @MainActor
    func readPasteboard() async -> [ProbeItem] {
        let pb = UIPasteboard.general
        let changeCount = pb.changeCount

        // Predicates only. None of these reads content, so none of them raises
        // the paste banner.
        let hasStrings = pb.hasStrings
        let hasURLs = pb.hasURLs
        let hasImages = pb.hasImages
        let hasColors = pb.hasColors
        let itemCount = pb.numberOfItems

        // Delta since the previous probe run = number of copy operations in
        // between. This is the actual passive signal, and it needs two runs.
        let hadPrior = DeviceProbeLedger.has(DeviceProbeLedger.kPasteChange)
        let prior = DeviceProbeLedger.count(DeviceProbeLedger.kPasteChange)
        let priorSeen = DeviceProbeLedger.string(DeviceProbeLedger.kPasteSeenAt)
        let delta = hadPrior ? changeCount - prior : 0
        DeviceProbeLedger.setInt(DeviceProbeLedger.kPasteChange, changeCount)
        DeviceProbeLedger.setString(DeviceProbeLedger.kPasteSeenAt, ProbeEnv.iso.string(from: Date()))

        var types: [String] = []
        if hasStrings { types.append("strings") }
        if hasURLs { types.append("URLs") }
        if hasImages { types.append("images") }
        if hasColors { types.append("colors") }

        return [ProbeItem(
            "device.pasteboard", "Pasteboard change counter",
            hadPrior ? .ok : .empty,
            value: hadPrior
                ? "changeCount \(changeCount) (+\(delta) since last run)"
                : "changeCount \(changeCount) (baseline recorded)",
            detail: """
            READ THE COUNT, NEVER THE CONTENT. Since iOS 16 any read of pasteboard CONTENT \
            (.string, .items, .url, .image) raises a user-visible "Probe pasted from Safari" \
            banner — or a full permission alert — which makes content reads useless as a passive \
            signal and actively hostile to the user. This probe reads none of it.

            changeCount, numberOfItems and the has* predicates are documented as NOT triggering \
            that banner, and changeCount alone is a real behavioural series: it is a monotonically \
            increasing count of copy operations DEVICE-WIDE, across every app. Sampling it on each \
            foreground gives copy-events-per-session with no permission and no visible trace. \
            Currently holding: \(types.isEmpty ? "nothing detectable" : types.joined(separator: ", ")).

            The delta is only meaningful from the second run onward. \
            \(priorSeen.map { "Previous sample: \($0)." } ?? "No previous sample — this run is the baseline.")

            Caveat for the collector: with Universal Clipboard on, changeCount also advances from \
            copies made on a Mac or iPad signed into the same Apple ID, so it is an Apple-ID-wide \
            counter rather than a device-wide one.
            """,
            extra: [
                "changeCount": ProbeEnv.int(changeCount),
                "priorChangeCount": ProbeEnv.int(prior),
                "deltaSinceLastRun": ProbeEnv.int(delta),
                "priorSampledAt": priorSeen ?? "never",
                "numberOfItems": ProbeEnv.int(itemCount),
                "hasStrings": DeviceProbeFmt.bool(hasStrings),
                "hasURLs": DeviceProbeFmt.bool(hasURLs),
                "hasImages": DeviceProbeFmt.bool(hasImages),
                "hasColors": DeviceProbeFmt.bool(hasColors),
                "UIPasteboard.changedNotification": UIPasteboard.changedNotification.rawValue,
                "contentReadRaisesBanner": "true (iOS 16+)"
            ]
        )]
    }
}

// MARK: - Section summary

enum DeviceProbeSummary {
    static func build(_ items: [ProbeItem]) -> String {
        var t: [ProbeStatus: Int] = [:]
        for i in items { t[i.status, default: 0] += 1 }
        func n(_ s: ProbeStatus) -> Int { t[s] ?? 0 }

        var parts: [String] = []
        parts.append("\(items.count) checks: \(n(.ok)) ok, \(n(.empty)) empty, \(n(.partial)) partial, "
                   + "\(n(.denied)) denied, \(n(.notDetermined)) notDetermined, "
                   + "\(n(.unavailable)) unavailable, \(n(.error)) error.")

        // The headline numbers a reader should look at first.
        let lockCount = DeviceProbeLedger.count(DeviceProbeLedger.kLockState)
            + DeviceProbeLedger.count(DeviceProbeLedger.kLockComplete)
        let shots = DeviceProbeLedger.count(DeviceProbeLedger.kScreenshot)
        let reboots = DeviceProbeLedger.count(DeviceProbeLedger.kRebootCount)

        parts.append("Cross-run ledger: springboard lock notifications fired \(lockCount)×, "
                   + "screenshots \(shots)×, reboots detected \(reboots)×"
                   + (DeviceProbeLedger.string(DeviceProbeLedger.kArmedAt).map { " since \($0)" } ?? "")
                   + ". Those three answers require TWO runs with a lock, a screenshot and "
                   + "(optionally) a reboot in between — a zero on the first run means nothing.")

        parts.append("Omitted deliberately, each because the exact symbol could not be verified "
                   + "against developer.apple.com and there is no Mac to compile against: "
                   + "UIPasteboard.detectPatterns (Result signature), "
                   + "UNNotificationSettings.directMessagesSetting (introducing iOS version — a "
                   + "post-17.0 symbol without an availability guard is a compile error), and "
                   + "UIAccessibility.buttonShapesEnabled (deprecated). "
                   + "The NSSystemTimeZoneDidChangeNotification name is reported as "
                   + "a string literal and is the one notification name here that was NOT "
                   + "compile-verified. Battery monitoring is left ENABLED on exit by design; "
                   + "proximity monitoring and device-orientation generation are both restored.")

        return parts.joined(separator: " ")
    }
}
