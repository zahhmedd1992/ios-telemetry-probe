import Foundation
import Intents
import UserNotifications
import AVFoundation
import AudioToolbox

#if canImport(AppIntents)
import AppIntents
#endif

#if canImport(FamilyControls)
import FamilyControls
#endif

// MARK: - FocusProbe
//
// "Focus & Attention" is the smallest section in this app and one of the most
// misunderstood, because the documentation and the folklore disagree about what
// is actually readable. This probe settles four separate questions with
// measurements rather than with citations:
//
//   1. INFocusStatusCenter — does it authorize on THIS build, and what does
//      `isFocused` actually return? This is a FOUR-state answer, not three:
//      true / false / nil-while-authorized / nil-because-unauthorized. Those
//      last two look identical in a naive report and mean opposite things.
//
//   2. SetFocusFilterIntent — the non-obvious upgrade. INFocusStatusCenter can
//      only ever tell you that SOME Focus is on. A Focus Filter is the only
//      supported way to learn WHICH Focus is on, because the mechanism is
//      inverted: the app does not query the system, the system hands the app
//      the per-Focus configuration the user attached to that specific Focus.
//      Reported here as availability ONLY — see the deliberate non-conformance
//      note below.
//
//   3. Ring/silent switch and Do Not Disturb — killed, definitively, with the
//      reasoning recorded so nobody re-opens it. Then measured anyway by timing
//      a silent system sound, clearly separated as an INFERENCE.
//
//   4. UNUserNotificationCenter's Focus-adjacent settings, which are the
//      legitimate per-app signals that survive when the Focus API does not.
//
// THE LOAD-BEARING FINDING THIS PROBE EXISTS TO CAPTURE
// -----------------------------------------------------
// `NSFocusStatusUsageDescription` IS present in this app's Info.plist (verified
// in project.yml), so the Info.plist gate is satisfied. But Focus Status is
// additionally gated on the "Communication Notifications" capability
// (entitlement `com.apple.developer.usernotifications.communication`), and NO
// tier in app/entitlements/ requests it — not tier0, not tier1, not tier2.
// The prediction is therefore: the plist string is correct and irrelevant, and
// requestAuthorization resolves without ever presenting a prompt. This probe
// records the predicted and the measured status side by side so the build tells
// us whether the capability is genuinely load-bearing or merely documented.
//
// DELIBERATE NON-CONFORMANCE (important, do not "fix" this)
// ---------------------------------------------------------
// This file does NOT declare a type conforming to `SetFocusFilterIntent`, even
// though that would be the strongest possible evidence. Declaring one has
// permanent side effects outside a probe run: it registers this app in the
// filter list of EVERY Focus in Settings, and it lets the system invoke
// `perform()` whenever the user changes Focus, forever, with the app not
// running. A telemetry probe must stay read-only and side-effect-free. What is
// reported instead is compile-time availability plus the measured presence of
// the compiled `Metadata.appintents` bundle, which is the real runtime evidence
// that App Intents metadata was extracted into this binary at all.
//
// NO BACKFILL WINDOW TO MEASURE
// ------------------------------
// Every other probe in this app can be graded on "how far back does history go".
// This one cannot, and that is a property of the APIs, not an omission: Focus
// status, notification settings, and ringer state are all strictly
// point-in-time. There is no historical query surface anywhere in this section,
// so no oldest-datum measurement is reported.

struct FocusProbe: TelemetryProbe {
    let key = "focus"
    let title = "Focus & Attention"

    func run() async -> ProbeSection {
        var items: [ProbeItem] = []

        items.append(contentsOf: FocusProbeSupport.bundleGateItems())
        items.append(contentsOf: await FocusProbeSupport.focusStatusItems())
        items.append(contentsOf: FocusProbeSupport.focusFilterItems())
        items.append(contentsOf: await FocusProbeSupport.notificationItems())
        items.append(contentsOf: await FocusProbeSupport.screenTimeItems())

        // Ringer verdict is a static, definitive conclusion — cheap and safe.
        items.append(FocusProbeSupport.ringerVerdictItem())
        items.append(contentsOf: FocusProbeSupport.audioContextItems())

        // The timing inference runs LAST and inside its own hard deadline. It is
        // the only part of this probe that makes noise-adjacent system calls, so
        // if it wedges, every read-only item above is already in the array.
        let muteItems = await withProbeTimeout(
            8.0,
            fallback: [ProbeItem(
                "focus.ringer.timingInference",
                "Ring/silent switch (timing inference)",
                .error,
                value: "timed out",
                detail: "The silent-system-sound timing test did not complete within 8s. No inference is reported: a stalled completion handler is indistinguishable from a muted device, and guessing here would poison the dataset with a fake 'muted' reading."
            )]
        ) {
            await FocusProbeSupport.ringerTimingItems()
        }
        items.append(contentsOf: muteItems)

        return section(FocusProbeSupport.summarize(items), items)
    }
}

// MARK: - Resume-exactly-once gate

/// A one-shot claim ticket for continuation resumption.
///
/// Every callback API wrapped in this file has TWO possible resumers: the real
/// callback, and an internal watchdog. Whichever arrives first wins; the loser
/// is dropped. Without this, a framework callback that never fires (or fires
/// twice, which `AudioServicesPlaySystemSoundWithCompletion` and delegate-style
/// APIs can do) either leaks the continuation forever or traps the process.
///
/// Note this is deliberately paired with a per-call watchdog rather than
/// relying on the outer `withProbeTimeout`. `withProbeTimeout` abandons the
/// losing child task — it does NOT resume that task's continuation — so an outer
/// timeout alone would still leak. The watchdog inside each continuation is what
/// actually guarantees "resumed exactly once on every path".
final class FocusProbeGate {
    private let lock = NSLock()
    private var claimed = false

    /// Returns true exactly once, for the first caller only.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

// MARK: - Measurement result types

struct FocusProbeMuteOutcome {
    var createStatus: OSStatus = 0
    var playedSeconds: Double?
    var wavSeconds: Double = 0
    var failure: String?
}

// MARK: - Support

enum FocusProbeSupport {

    // ------------------------------------------------------------------
    // Shared constants
    // ------------------------------------------------------------------

    /// Verified verbatim from Apple's own App Store validation warning
    /// ITMS-90894, which names this key and additionally requires
    /// `INSendMessageIntent` or `INStartCallIntent` in `NSUserActivityTypes`.
    static let communicationEntitlementKey = "com.apple.developer.usernotifications.communication"

    /// Length of the synthesized silent WAV used for the ringer timing test.
    static let muteWavSeconds: Double = 0.50
    /// Below this elapsed time, playback plainly did not happen.
    static let muteThresholdSeconds: Double = 0.20

    // ------------------------------------------------------------------
    // 1. Bundle-level gates (measured against the RUNNING bundle, not the yml)
    // ------------------------------------------------------------------

    static func bundleGateItems() -> [ProbeItem] {
        var out: [ProbeItem] = []
        let info = Bundle.main.infoDictionary ?? [:]

        // --- Info.plist usage string ---
        let usage = info["NSFocusStatusUsageDescription"] as? String
        if let usage, !usage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append(ProbeItem(
                "focus.plist.usageDescription",
                "NSFocusStatusUsageDescription",
                .ok,
                value: "present — \(usage.count) chars",
                detail: "Verified as the correct key name for Focus Status (not NSFocusStatusAuthorizationUsageDescription, which appears in some secondhand write-ups and is wrong). Read here from the RUNNING bundle's Info.plist rather than from project.yml, because the build could have dropped it. Its presence is necessary but NOT sufficient — see the capability item below.",
                extra: ["key": "NSFocusStatusUsageDescription", "length": String(usage.count)]
            ))
        } else {
            out.append(ProbeItem(
                "focus.plist.usageDescription",
                "NSFocusStatusUsageDescription",
                .unavailable,
                value: "absent",
                detail: "Without this key iOS refuses the Focus Status authorization request outright and never shows a prompt. If this reads 'absent', the authorization result below is explained entirely by this and nothing further should be inferred from it."
            ))
        }

        // --- Communication Notifications capability, measured three ways ---
        // (a) Does the running bundle carry the NSUserActivityTypes that Apple
        //     requires alongside the entitlement? This is a public, readable
        //     proxy for the capability having ever been configured.
        let activityTypes = (info["NSUserActivityTypes"] as? [String]) ?? []
        let commsIntents = activityTypes.filter { $0 == "INSendMessageIntent" || $0 == "INStartCallIntent" }

        out.append(ProbeItem(
            "focus.capability.communicationNotifications",
            "Communication Notifications capability",
            commsIntents.isEmpty ? .unavailable : .partial,
            value: commsIntents.isEmpty
                ? "not configured in this bundle"
                : "companion keys present: \(commsIntents.joined(separator: ", "))",
            detail: "Focus Status is gated on BOTH the Info.plist usage string AND Xcode's 'Communication Notifications' capability (entitlement key \(communicationEntitlementKey)). No entitlement tier in app/entitlements/ requests it — not tier0, tier1, or tier2 — so this build is predicted to fail authorization no matter what the plist says. There is no public API to read the running binary's entitlement blob on iOS (SecTaskCopyValueForEntitlement is unexported there), so this item reports the readable proxy instead: Apple's ITMS-90894 validation requires apps carrying that entitlement to also list INSendMessageIntent or INStartCallIntent in NSUserActivityTypes. Their absence is consistent with the capability being absent; their presence would not by itself prove it is granted. The measured authorization status below is the real verdict.",
            extra: [
                "entitlementKey": communicationEntitlementKey,
                "nsUserActivityTypesCount": String(activityTypes.count),
                "communicationIntentKeys": commsIntents.isEmpty ? "none" : commsIntents.joined(separator: ",")
            ]
        ))

        return out
    }

    // ------------------------------------------------------------------
    // 2. INFocusStatusCenter
    // ------------------------------------------------------------------

    static func authName(_ s: INFocusStatusAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: return "notDetermined"
        case .restricted:    return "restricted"
        case .denied:        return "denied"
        case .authorized:    return "authorized"
        @unknown default:    return "unknown(\(s.rawValue))"
        }
    }

    static func authProbeStatus(_ s: INFocusStatusAuthorizationStatus) -> ProbeStatus {
        switch s {
        case .authorized:    return .ok
        case .denied:        return .denied
        case .restricted:    return .denied
        case .notDetermined: return .notDetermined
        @unknown default:    return .partial
        }
    }

    /// Wraps the completion-style authorization request with an internal
    /// watchdog so the continuation is resumed exactly once even if the
    /// framework never calls back (which is the observed behaviour when the
    /// capability is missing on some builds).
    static func requestFocusAuthorization(timeout: Double) async -> INFocusStatusAuthorizationStatus? {
        let gate = FocusProbeGate()
        return await withCheckedContinuation { (cont: CheckedContinuation<INFocusStatusAuthorizationStatus?, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if gate.claim() { cont.resume(returning: nil) }
            }
            INFocusStatusCenter.default.requestAuthorization { status in
                if gate.claim() { cont.resume(returning: status) }
            }
        }
    }

    static func focusStatusItems() async -> [ProbeItem] {
        var out: [ProbeItem] = []

        let before = INFocusStatusCenter.default.authorizationStatus
        out.append(ProbeItem(
            "focus.status.authorizationBefore",
            "Focus authorization (before asking)",
            authProbeStatus(before),
            value: authName(before),
            detail: "Read before calling requestAuthorization, so it reflects any decision already on file from a previous run or a previous install of this bundle identifier.",
            extra: ["raw": String(before.rawValue)]
        ))

        let requested = await requestFocusAuthorization(timeout: 12.0)
        if let requested {
            out.append(ProbeItem(
                "focus.status.requestAuthorization",
                "requestAuthorization result",
                authProbeStatus(requested),
                value: authName(requested),
                detail: before == requested
                    ? "The request returned the same status it started with. When that status is denied or restricted and no prompt was shown, the cause is the missing Communication Notifications capability, not a user decision — iOS refuses the request before it ever reaches the user."
                    : "Status changed from \(authName(before)) to \(authName(requested)) — a prompt was genuinely presented and answered during this run.",
                extra: [
                    "raw": String(requested.rawValue),
                    "changedFrom": authName(before),
                    "promptLikelyShown": before == requested ? "false" : "true"
                ]
            ))
        } else {
            out.append(ProbeItem(
                "focus.status.requestAuthorization",
                "requestAuthorization result",
                .error,
                value: "no callback within 12s",
                detail: "INFocusStatusCenter.requestAuthorization never invoked its completion handler. The continuation was resumed by this probe's internal watchdog. Treat the authorization state as indeterminate for this run."
            ))
        }

        let after = INFocusStatusCenter.default.authorizationStatus
        out.append(ProbeItem(
            "focus.status.authorizationAfter",
            "Focus authorization (after asking)",
            authProbeStatus(after),
            value: authName(after),
            detail: "Re-read from the center rather than trusting the completion handler's argument. These disagree in practice when the request is refused at the entitlement layer.",
            extra: [
                "raw": String(after.rawValue),
                "agreesWithCallback": requested.map { $0 == after ? "true" : "false" } ?? "n/a"
            ]
        ))

        // --- The four-state isFocused reading ---
        let isAuthorized = (after == .authorized)
        let focused = INFocusStatusCenter.default.focusStatus.isFocused

        let focusItem: ProbeItem
        switch (isAuthorized, focused) {
        case (true, .some(true)):
            focusItem = ProbeItem(
                "focus.status.isFocused",
                "Is a Focus currently active?",
                .ok,
                value: "true — a Focus is ON",
                detail: "Authorized, and the system returned a definite yes. Note carefully what this does NOT say: it does not identify WHICH Focus (Do Not Disturb, Sleep, Work, Personal, Driving, Fitness, Mindfulness, Gaming, Reading, or any user-created Focus), does not give a start time, does not give a schedule, and does not say whether this app is on that Focus's allow list. It is one bit.",
                extra: ["isFocused": "true", "sampledAt": ProbeEnv.iso.string(from: Date())]
            )
        case (true, .some(false)):
            focusItem = ProbeItem(
                "focus.status.isFocused",
                "Is a Focus currently active?",
                .ok,
                value: "false — no Focus active",
                detail: "Authorized, and the system returned a definite no. This is real data, not a failure: it means no Focus of any kind was engaged at sample time.",
                extra: ["isFocused": "false", "sampledAt": ProbeEnv.iso.string(from: Date())]
            )
        case (true, .none):
            focusItem = ProbeItem(
                "focus.status.isFocused",
                "Is a Focus currently active?",
                .empty,
                value: "nil — authorized but no determination",
                detail: "This is the third state and it is genuinely distinct from the unauthorized case below. Authorization IS granted, yet INFocusStatus.isFocused is a Bool? and the system declined to commit to a value. A collector must not coerce this to false — 'unknown' and 'no Focus' are different facts, and flattening them silently manufactures data.",
                extra: ["isFocused": "nil", "reason": "authorized-but-undetermined"]
            )
        // `default` rather than `(false, _)`: the three authorized combinations
        // are fully enumerated above, so this catches exactly the unauthorized
        // cases — while making the switch exhaustive by construction instead of
        // relying on the checker to prove exhaustiveness over a (Bool, Bool?)
        // tuple. Same semantics, no chance of a build-breaking diagnostic.
        default:
            focusItem = ProbeItem(
                "focus.status.isFocused",
                "Is a Focus currently active?",
                after == .notDetermined ? .notDetermined : .denied,
                value: "nil — not authorized (\(authName(after)))",
                detail: "The fourth state. isFocused is nil here because permission was never granted, which carries no information about the device's actual Focus state. Distinguishing this from the authorized-but-nil case is the whole point of reporting four states rather than three: they produce identical values and mean opposite things.",
                extra: ["isFocused": "nil", "reason": "unauthorized", "authorizationStatus": authName(after)]
            )
        }
        out.append(focusItem)

        // --- Explicit scope statement, recorded as its own item so it lands in
        //     the JSON report and not just in this source file. ---
        out.append(ProbeItem(
            "focus.status.scope",
            "What Focus Status does and does not reveal",
            .partial,
            value: "one boolean, no identity",
            detail: "REVEALS: a single Bool? saying some Focus is active, sampled on demand; plus, for apps with the capability, the ability to share that bit with contacts through Messages. DOES NOT REVEAL: which Focus is active; the Focus's name, mode identifier, or icon; when it started or when it is scheduled to end; whether it was enabled manually, by schedule, by location, or by an automation; whether this app is on its allow list; the notification-summary schedule; or any history whatsoever. There is no public API for any of those through this class. The only supported route to Focus IDENTITY is a Focus Filter — see the SetFocusFilterIntent items below.",
            extra: ["apiClass": "INFocusStatusCenter", "framework": "Intents", "sinceOS": "iOS 15.0"]
        ))

        return out
    }

    // ------------------------------------------------------------------
    // 3. SetFocusFilterIntent — availability only, never a conformance
    // ------------------------------------------------------------------

    static func focusFilterItems() -> [ProbeItem] {
        var out: [ProbeItem] = []

        #if canImport(AppIntents)
        if #available(iOS 16.0, *) {
            out.append(ProbeItem(
                "focus.filter.sdkAvailability",
                "SetFocusFilterIntent available on this SDK",
                .ok,
                value: "yes — AppIntents imports, iOS 16+ satisfied",
                detail: "RECOMMENDED PATH, and the single most useful finding in this section. A Focus Filter inverts the direction of the question. INFocusStatusCenter has the app ask the system 'is something on?' and the system answers with one anonymous bit. SetFocusFilterIntent has the USER attach a per-Focus configuration to this app inside Settings > Focus > <name> > Focus Filters, and then the SYSTEM calls perform() on this app handing it exactly that configuration whenever that Focus engages or disengages. Because each Focus carries its own distinct configuration, receiving one is equivalent to being told which Focus is now active — with no entitlement, no Communication Notifications capability, and no authorization prompt anywhere. It also fires when the app is not running, which INFocusStatusCenter cannot do. The costs are that it is user-configured rather than automatic (nothing arrives until the user adds the filter), and that it is push-only — there is no way to ask 'which Focus is on right now?' outside a delivered perform() call.",
                extra: ["framework": "AppIntents", "protocol": "SetFocusFilterIntent", "sinceOS": "iOS 16.0"]
            ))
        } else {
            out.append(ProbeItem(
                "focus.filter.sdkAvailability",
                "SetFocusFilterIntent available on this SDK",
                .unavailable,
                value: "no — running below iOS 16",
                detail: "AppIntents imports but the runtime is below iOS 16. Unreachable in practice: this target's deployment minimum is iOS 17.0."
            ))
        }
        #else
        out.append(ProbeItem(
            "focus.filter.sdkAvailability",
            "SetFocusFilterIntent available on this SDK",
            .unavailable,
            value: "no — AppIntents does not import",
            detail: "The AppIntents framework is not importable in this build configuration, so Focus Filters are unreachable regardless of OS version."
        ))
        #endif

        // Runtime evidence: was App Intents metadata actually extracted into
        // this bundle? This is a real filesystem measurement of the built
        // product, not an inference from the source.
        let metaURL = Bundle.main.bundleURL.appendingPathComponent("Metadata.appintents")
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: metaURL.path, isDirectory: &isDir)
        var childCount = -1
        if exists, isDir.boolValue {
            let kids = (try? FileManager.default.contentsOfDirectory(atPath: metaURL.path)) ?? []
            childCount = kids.count
        }

        out.append(ProbeItem(
            "focus.filter.metadataBundle",
            "Compiled App Intents metadata in bundle",
            exists ? .ok : .empty,
            value: exists
                ? "present (\(isDir.boolValue ? "directory" : "file")\(childCount >= 0 ? ", \(childCount) entries" : ""))"
                : "absent",
            detail: "Measured directly on the running bundle. Metadata.appintents is emitted by the App Intents extraction build phase and is what the system reads to discover an app's intents without launching it. Reported as measured, with no theory attached about the cause: this probe declares no App Intents of its own, and other probes in this app may or may not. Its presence means extraction ran; its absence means no App Intents metadata shipped, in which case no Focus Filter this app declared would ever be offered in Settings.",
            extra: [
                "path": "Metadata.appintents",
                "exists": exists ? "true" : "false",
                "isDirectory": isDir.boolValue ? "true" : "false",
                "entryCount": childCount >= 0 ? String(childCount) : "n/a"
            ]
        ))

        out.append(ProbeItem(
            "focus.filter.notDeclaredHere",
            "Focus Filter deliberately not declared",
            .partial,
            value: "availability reported, conformance withheld",
            detail: "This probe intentionally declares no SetFocusFilterIntent conformance. Doing so is not a read: it permanently registers this app in the Focus Filters list of every Focus in Settings and authorizes the system to invoke perform() on Focus changes indefinitely, with the app not running. That is a side effect a telemetry probe must not have. The capability is therefore reported, not exercised — and this is the one item in this section that a future collector should convert into a real conformance once it is a collector rather than a probe.",
            extra: ["reason": "side-effect-free probe", "upgradePath": "declare SetFocusFilterIntent in the collector, not the probe"]
        ))

        return out
    }

    // ------------------------------------------------------------------
    // 4. UNUserNotificationCenter — Focus-adjacent per-app settings
    // ------------------------------------------------------------------

    static func unAuthName(_ s: UNAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: return "notDetermined"
        case .denied:        return "denied"
        case .authorized:    return "authorized"
        case .provisional:   return "provisional"
        case .ephemeral:     return "ephemeral"
        @unknown default:    return "unknown(\(s.rawValue))"
        }
    }

    static func settingName(_ s: UNNotificationSetting) -> String {
        switch s {
        case .notSupported: return "notSupported"
        case .disabled:     return "disabled"
        case .enabled:      return "enabled"
        @unknown default:   return "unknown(\(s.rawValue))"
        }
    }

    /// `.notSupported` means two completely different things depending on the
    /// authorization status beside it, so status mapping needs that context.
    static func settingProbeStatus(_ s: UNNotificationSetting, authorized: Bool) -> ProbeStatus {
        switch s {
        case .enabled, .disabled: return .ok
        case .notSupported:       return authorized ? .unavailable : .notDetermined
        @unknown default:         return .partial
        }
    }

    static func requestNotificationAuth(options: UNAuthorizationOptions,
                                        timeout: Double) async -> (granted: Bool?, error: NSError?) {
        let gate = FocusProbeGate()
        return await withCheckedContinuation { (cont: CheckedContinuation<(Bool?, NSError?), Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if gate.claim() { cont.resume(returning: (nil, nil)) }
            }
            UNUserNotificationCenter.current().requestAuthorization(options: options) { granted, err in
                if gate.claim() { cont.resume(returning: (granted, err as NSError?)) }
            }
        }
    }

    static func fetchNotificationSettings(timeout: Double) async -> UNNotificationSettings? {
        let gate = FocusProbeGate()
        return await withCheckedContinuation { (cont: CheckedContinuation<UNNotificationSettings?, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if gate.claim() { cont.resume(returning: nil) }
            }
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                if gate.claim() { cont.resume(returning: settings) }
            }
        }
    }

    static func notificationItems() async -> [ProbeItem] {
        var out: [ProbeItem] = []

        // Ask for the standard set first. This is idempotent — iOS presents the
        // prompt at most once per install, so if a sibling probe already asked,
        // this returns immediately without a second prompt.
        let std = await requestNotificationAuth(options: [.alert, .sound, .badge], timeout: 20.0)
        out.append(ProbeItem(
            "focus.notif.requestAuthorization",
            "Notification authorization request",
            std.granted == nil ? .error : (std.granted == true ? .ok : .denied),
            value: std.granted == nil ? "no callback within 20s" : (std.granted == true ? "granted" : "not granted"),
            detail: "Requested [.alert, .sound, .badge]. This is required before the Focus-related settings below carry any information at all — while authorization is notDetermined, every one of them reports notSupported, which is an artifact of not having asked rather than a statement about the device."
                + (std.error.map { " Error: \($0.domain) \($0.code) — \($0.localizedDescription)" } ?? ""),
            extra: [
                "options": "alert,sound,badge",
                "errorDomain": std.error?.domain ?? "none",
                "errorCode": std.error.map { String($0.code) } ?? "none"
            ]
        ))

        // Critical alerts are entitlement-gated. There are TWO plausible
        // outcomes without the entitlement and they look nothing alike, so
        // record which one actually happened.
        let crit = await requestNotificationAuth(options: [.criticalAlert], timeout: 20.0)

        guard let settings = await fetchNotificationSettings(timeout: 15.0) else {
            out.append(ProbeItem(
                "focus.notif.settings",
                "Notification settings",
                .error,
                value: "no callback within 15s",
                detail: "UNUserNotificationCenter.getNotificationSettings never called back; the continuation was resumed by this probe's watchdog."
            ))
            return out
        }

        let auth = settings.authorizationStatus
        let isAuth = (auth == .authorized || auth == .provisional || auth == .ephemeral)

        out.append(ProbeItem(
            "focus.notif.authorizationStatus",
            "Notification authorization status",
            isAuth ? .ok : (auth == .denied ? .denied : .notDetermined),
            value: unAuthName(auth),
            detail: "Recorded separately from the request result above, because the two disagree constantly — a request can report granted while the effective status is provisional, and that difference changes how every setting below must be read.",
            extra: ["raw": String(auth.rawValue)]
        ))

        // --- Critical alert: entitlement gate, two branches ---
        let critSetting = settings.criticalAlertSetting
        let critValue: String
        let critDetailExtra: String
        if let err = crit.error {
            critValue = "request threw — setting is \(settingName(critSetting))"
            critDetailExtra = "The request returned an error: \(err.domain) \(err.code) — \(err.localizedDescription)."
        } else if crit.granted == true && critSetting == .notSupported {
            critValue = "request 'granted' but setting is notSupported"
            critDetailExtra = "This is the branch that catches people out: requesting .criticalAlert without the entitlement does NOT throw and does NOT return false — it reports granted, while criticalAlertSetting stays notSupported forever. Trusting the request's return value here would produce a confidently wrong capability record. The setting is the truth; the grant flag is not."
        } else if crit.granted == nil {
            critValue = "no callback — setting is \(settingName(critSetting))"
            critDetailExtra = "The .criticalAlert request never called back within 20s; only the settings read below is trustworthy."
        } else {
            critValue = "granted=\(crit.granted == true) — setting is \(settingName(critSetting))"
            critDetailExtra = "Request and setting agree."
        }

        out.append(ProbeItem(
            "focus.notif.criticalAlertSetting",
            "Critical alerts (pierces Focus AND silent switch)",
            settingProbeStatus(critSetting, authorized: isAuth),
            value: critValue,
            detail: "Critical alerts are the strongest Focus-related signal in the notification system: they bypass every Focus, bypass Do Not Disturb, and sound even when the ring/silent switch is set to silent. Access requires the approval-gated com.apple.developer.usernotifications.critical-alerts entitlement, which no tier in this project requests, so notSupported is the expected reading. " + critDetailExtra,
            extra: [
                "setting": settingName(critSetting),
                "raw": String(critSetting.rawValue),
                "requestGranted": crit.granted.map { $0 ? "true" : "false" } ?? "no-callback",
                "requestErrorDomain": crit.error?.domain ?? "none",
                "requestErrorCode": crit.error.map { String($0.code) } ?? "none",
                "entitlementRequired": "com.apple.developer.usernotifications.critical-alerts"
            ]
        ))

        // --- The three iOS 15+ Focus-interaction settings ---
        let trio: [(String, String, UNNotificationSetting, String)] = [
            ("scheduledDelivery",
             "Scheduled Delivery / Notification Summary",
             settings.scheduledDeliverySetting,
             "Reports whether the user has this app's notifications held for the Notification Summary instead of delivered on arrival. Summary scheduling is configured alongside Focus and is the closest public signal to 'the user has deliberately deferred this app'. Enabled here means delivery is BATCHED, not that notifications are more prominent."),
            ("timeSensitive",
             "Time Sensitive notifications",
             settings.timeSensitiveSetting,
             "Reports whether this app may mark notifications time-sensitive, which lets them break through an active Focus for up to an hour. This is the single most direct per-app Focus-interaction bit available without any entitlement: it is the user's answer to 'may this app interrupt my Focus?'. Requires no special capability, unlike critical alerts."),
            ("directMessages",
             "Direct Messages styling",
             settings.directMessagesSetting,
             "Reports whether this app's notifications are treated as direct messages, which affects communication-notification presentation and Focus allow-list behaviour for people rather than apps. Expected notSupported for an app that donates no communication intents.")
        ]

        for (slug, label, setting, why) in trio {
            out.append(ProbeItem(
                "focus.notif.\(slug)Setting",
                label,
                settingProbeStatus(setting, authorized: isAuth),
                value: settingName(setting),
                detail: why + (isAuth ? "" : " NOTE: notification authorization is \(unAuthName(auth)), so a notSupported reading here reflects the missing authorization, not a device or OS limitation."),
                extra: [
                    "setting": settingName(setting),
                    "raw": String(setting.rawValue),
                    "sinceOS": "iOS 15.0",
                    "authorizationStatus": unAuthName(auth)
                ]
            ))
        }

        // Context settings — cheap, and they explain the trio above.
        let ctx: [(String, String, UNNotificationSetting)] = [
            ("alert", "Alert setting", settings.alertSetting),
            ("sound", "Sound setting", settings.soundSetting),
            ("badge", "Badge setting", settings.badgeSetting),
            ("lockScreen", "Lock screen setting", settings.lockScreenSetting),
            ("notificationCenter", "Notification Center setting", settings.notificationCenterSetting),
            ("announcement", "Announce notifications (Siri)", settings.announcementSetting)
        ]
        for (slug, label, setting) in ctx {
            out.append(ProbeItem(
                "focus.notif.\(slug)Setting",
                label,
                settingProbeStatus(setting, authorized: isAuth),
                value: settingName(setting),
                detail: "Context for the Focus-specific settings above; a disabled alert or sound channel changes what a Focus can even suppress.",
                extra: ["setting": settingName(setting), "raw": String(setting.rawValue)]
            ))
        }

        out.append(ProbeItem(
            "focus.notif.showPreviews",
            "Show previews setting",
            isAuth ? .ok : .notDetermined,
            value: {
                switch settings.showPreviewsSetting {
                case .always:       return "always"
                case .whenAuthenticated: return "whenAuthenticated"
                case .never:        return "never"
                @unknown default:   return "unknown(\(settings.showPreviewsSetting.rawValue))"
                }
            }(),
            detail: "Privacy-adjacent and Focus-adjacent: whenAuthenticated means content is hidden until Face ID succeeds, which interacts with how much a Focus actually conceals on the Lock Screen.",
            extra: ["raw": String(settings.showPreviewsSetting.rawValue)]
        ))

        return out
    }

    // ------------------------------------------------------------------
    // 5. Do Not Disturb / ring-silent — the definitive verdict
    // ------------------------------------------------------------------

    static func ringerVerdictItem() -> ProbeItem {
        ProbeItem(
            "focus.ringer.publicAPI",
            "Ring/silent switch & Do Not Disturb state",
            .unavailable,
            value: "NO public API — question closed",
            detail: "VERDICT, stated definitively so this idea is killed rather than re-litigated. There is no public iOS API, on any OS version through iOS 26, that reports (a) the physical ring/silent switch or Action Button silent state, or (b) Do Not Disturb specifically as distinct from any other Focus. What exists and what it is NOT: INFocusStatusCenter returns one anonymous bit that cannot distinguish Do Not Disturb from Sleep or from a user-created Focus, and requires a capability this build lacks. AVAudioSession exposes route, volume, and secondaryAudioShouldBeSilencedHint — none of which is the ringer switch; the hint means other audio wants ducking, not that the device is muted. UIApplication, UIDevice, and ProcessInfo expose nothing relevant. The commonly cited Darwin notification key com.apple.springboard.ringerstate is NOT public API — undocumented Darwin notify keys are not API merely because notify_register_dispatch is public — and it is out of bounds under this project's public-API-only rule. Apple's stated rationale is deliberate: apps are meant to declare an AVAudioSession category and let the system apply the correct silent behaviour, rather than each app inventing its own. The ONLY remaining route is a timing inference, reported as a separate item below and explicitly not a state read.",
            extra: [
                "publicAPIExists": "false",
                "checkedAPIs": "INFocusStatusCenter,AVAudioSession,UIApplication,UIDevice,ProcessInfo,UNNotificationSettings",
                "rejectedPrivateRoute": "com.apple.springboard.ringerstate (Darwin notify, undocumented)"
            ]
        )
    }

    static func audioContextItems() -> [ProbeItem] {
        let s = AVAudioSession.sharedInstance()
        let outs = s.currentRoute.outputs.map { $0.portType.rawValue }

        return [
            ProbeItem(
                "focus.audio.sessionState",
                "Audio session state on entry",
                .ok,
                value: "\(s.category.rawValue) / \(s.mode.rawValue)",
                detail: "Recorded BEFORE this probe touches the session, and reported as its own item because it is a genuine cross-probe finding: probes run sequentially in one process, and an earlier probe that recorded audio can leave the shared session in a recording category, which changes how system sounds behave for everything after it. This probe restores whatever it found.",
                extra: [
                    "category": s.category.rawValue,
                    "mode": s.mode.rawValue,
                    "categoryOptions": String(s.categoryOptions.rawValue),
                    "isOtherAudioPlaying": s.isOtherAudioPlaying ? "true" : "false"
                ]
            ),
            ProbeItem(
                "focus.audio.route",
                "Current audio output route",
                outs.isEmpty ? .empty : .ok,
                value: outs.isEmpty ? "no outputs reported" : outs.joined(separator: ", "),
                detail: "Load-bearing for the timing inference below: the ring/silent switch only governs the built-in speaker. On headphones, Bluetooth, AirPlay, or CarPlay the sound plays regardless of switch position, so any timing-based mute inference is invalid on those routes and is suppressed rather than reported.",
                extra: ["outputs": outs.isEmpty ? "none" : outs.joined(separator: ","),
                        "outputCount": String(outs.count)]
            ),
            ProbeItem(
                "focus.audio.outputVolume",
                "System output volume",
                .ok,
                value: String(format: "%.3f", s.outputVolume),
                detail: "Media volume, which is a different control from the ringer volume and is NOT a mute indicator — a device at volume 0 with the ringer on and a device at full volume set to silent both exist. Included because it is a real sampled value and a collector will want it.",
                extra: ["outputVolume": String(format: "%.4f", s.outputVolume),
                        "secondaryAudioShouldBeSilencedHint": s.secondaryAudioShouldBeSilencedHint ? "true" : "false"]
            )
        ]
    }

    /// Builds a valid 16-bit PCM mono RIFF/WAVE file containing pure silence.
    /// Synthesized at runtime so this probe stays a single file with no asset.
    static func silentWavData(seconds: Double) -> Data {
        let sampleRate: UInt32 = 44_100
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let blockAlign: UInt16 = channels * (bitsPerSample / 8)
        let byteRate: UInt32 = sampleRate * UInt32(blockAlign)
        let frames = UInt32(max(1.0, seconds * Double(sampleRate)))
        let dataBytes = frames * UInt32(blockAlign)

        var d = Data()
        func put32(_ v: UInt32) {
            var x = v.littleEndian
            withUnsafeBytes(of: &x) { d.append(contentsOf: $0) }
        }
        func put16(_ v: UInt16) {
            var x = v.littleEndian
            withUnsafeBytes(of: &x) { d.append(contentsOf: $0) }
        }

        d.append(contentsOf: Array("RIFF".utf8))
        put32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        put32(16)                 // PCM fmt chunk size
        put16(1)                  // format = PCM
        put16(channels)
        put32(sampleRate)
        put32(byteRate)
        put16(blockAlign)
        put16(bitsPerSample)
        d.append(contentsOf: Array("data".utf8))
        put32(dataBytes)
        d.append(Data(count: Int(dataBytes)))
        return d
    }

    static func measureMute() async -> FocusProbeMuteOutcome {
        var outcome = FocusProbeMuteOutcome()
        outcome.wavSeconds = muteWavSeconds

        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("focusprobe-silence.wav")
        do {
            try silentWavData(seconds: muteWavSeconds).write(to: url, options: .atomic)
        } catch {
            outcome.failure = "Could not write the temporary silent WAV: \(error.localizedDescription)"
            return outcome
        }
        defer { try? FileManager.default.removeItem(at: url) }

        var soundID: SystemSoundID = 0
        let createStatus = AudioServicesCreateSystemSoundID(url as CFURL, &soundID)
        outcome.createStatus = createStatus
        // Compared against the literal 0 rather than kAudioServicesNoError so
        // this does not depend on how that CF_ENUM constant happens to import.
        guard createStatus == 0 else {
            outcome.failure = "AudioServicesCreateSystemSoundID returned OSStatus \(createStatus). No inference is possible; this is a file/codec failure, NOT evidence of a muted device."
            return outcome
        }

        let started = Date()
        let gate = FocusProbeGate()
        let elapsed: Double? = await withCheckedContinuation { (cont: CheckedContinuation<Double?, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + 5.0) {
                if gate.claim() { cont.resume(returning: nil) }
            }
            AudioServicesPlaySystemSoundWithCompletion(soundID) {
                if gate.claim() { cont.resume(returning: Date().timeIntervalSince(started)) }
            }
        }

        // Dispose only AFTER the completion has been accounted for. Disposing
        // while the sound is still queued can drop the completion entirely.
        AudioServicesDisposeSystemSoundID(soundID)

        if let elapsed {
            outcome.playedSeconds = elapsed
        } else {
            outcome.failure = "The system-sound completion handler did not fire within 5s. No inference is reported: a stalled handler and a muted device produce the same silence, and reporting 'muted' here would be a fabricated reading."
        }
        return outcome
    }

    static func ringerTimingItems() async -> [ProbeItem] {
        let session = AVAudioSession.sharedInstance()

        // Route gate first — on any non-speaker route the inference is invalid.
        let outs = session.currentRoute.outputs.map { $0.portType.rawValue }
        let speakerRoute = outs.contains(AVAudioSession.Port.builtInSpeaker.rawValue)
            || outs.contains(AVAudioSession.Port.builtInReceiver.rawValue)
        if !speakerRoute {
            return [ProbeItem(
                "focus.ringer.timingInference",
                "Ring/silent switch (timing inference)",
                .partial,
                value: "not attempted — route is \(outs.isEmpty ? "unknown" : outs.joined(separator: ", "))",
                detail: "Deliberately skipped rather than guessed. The ring/silent switch only suppresses audio on the built-in speaker; on headphones, Bluetooth, AirPlay, or CarPlay a system sound plays at full length regardless of switch position, so a timing measurement on this route would confidently report 'ringer on' for a device that is in fact silenced. Unplug external audio and re-run to get a reading.",
                extra: ["outputs": outs.isEmpty ? "none" : outs.joined(separator: ","), "attempted": "false"]
            )]
        }

        // Save the session state so an earlier probe's configuration survives.
        let priorCategory = session.category
        let priorMode = session.mode
        let priorOptions = session.categoryOptions

        // .ambient is inherently mixing AND honours the ring/silent switch, which
        // is exactly what this test needs. Note NO .mixWithOthers option is passed:
        // Apple permits that option only on playAndRecord, playback, and multiRoute,
        // so passing it here would throw, the `try?` would swallow it, and the
        // session would silently stay in whatever category an earlier probe left
        // behind — e.g. .record, under which the system sound never plays and the
        // callback returns instantly. That failure would look exactly like a muted
        // device. Hence the category actually in force is captured and reported.
        var setupError: String?
        do {
            try session.setCategory(.ambient, mode: .default, options: [])
        } catch {
            setupError = "setCategory(.ambient) failed: \(error.localizedDescription)"
        }
        do {
            try session.setActive(true, options: [])
        } catch {
            if setupError == nil { setupError = "setActive(true) failed: \(error.localizedDescription)" }
        }
        let categoryDuringTest = session.category
        let categoryHonoursSilentSwitch = (categoryDuringTest == .ambient || categoryDuringTest == .soloAmbient)

        let outcome = await measureMute()

        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        try? session.setCategory(priorCategory, mode: priorMode, options: priorOptions)

        var extra: [String: String] = [
            "wavSeconds": String(format: "%.3f", outcome.wavSeconds),
            "thresholdSeconds": String(format: "%.3f", muteThresholdSeconds),
            "createStatus": String(outcome.createStatus),
            "route": outs.joined(separator: ","),
            "priorCategory": priorCategory.rawValue,
            "priorMode": priorMode.rawValue,
            "priorCategoryOptions": String(priorOptions.rawValue),
            "categoryDuringTest": categoryDuringTest.rawValue,
            "categoryHonoursSilentSwitch": categoryHonoursSilentSwitch ? "true" : "false",
            "sessionSetupError": setupError ?? "none",
            "outputVolume": String(format: "%.4f", session.outputVolume),
            "isOtherAudioPlaying": session.isOtherAudioPlaying ? "true" : "false"
        ]

        // If the session could not be moved into a silent-switch-honouring
        // category, the timing signal is meaningless — suppress the inference
        // rather than emit a reading that would read as a confident "silent".
        if !categoryHonoursSilentSwitch {
            extra["attempted"] = "true"
            extra["inference"] = "none"
            return [ProbeItem(
                "focus.ringer.timingInference",
                "Ring/silent switch (timing inference)",
                .partial,
                value: "suppressed — session category is \(categoryDuringTest.rawValue)",
                detail: "The audio session could not be placed in .ambient, so it is in \(categoryDuringTest.rawValue), a category that does NOT honour the ring/silent switch. Under such a category a system sound either never plays or plays regardless of the switch, so the elapsed time carries no information about mute state. Suppressed deliberately: emitting it would look like a confident reading. Most likely cause is an earlier probe in this run leaving the shared session configured for recording. \(setupError ?? "No setCategory error was reported, which makes this more surprising, not less.")",
                extra: extra
            )]
        }

        // A non-zero create status or a missing completion is an ERROR, never a
        // "muted" reading. Conflating those is exactly how this technique
        // acquired its bad reputation.
        if let failure = outcome.failure {
            extra["attempted"] = "true"
            extra["inference"] = "none"
            return [ProbeItem(
                "focus.ringer.timingInference",
                "Ring/silent switch (timing inference)",
                .error,
                value: outcome.createStatus == 0 ? "no completion" : "OSStatus \(outcome.createStatus)",
                detail: failure,
                extra: extra
            )]
        }

        guard let played = outcome.playedSeconds else {
            extra["attempted"] = "true"
            extra["inference"] = "none"
            return [ProbeItem(
                "focus.ringer.timingInference",
                "Ring/silent switch (timing inference)",
                .error,
                value: "no measurement",
                detail: "The measurement completed without an elapsed time, which should be unreachable. Reported as an error rather than inferring anything.",
                extra: extra
            )]
        }

        let inferredMuted = played < muteThresholdSeconds
        extra["attempted"] = "true"
        extra["elapsedSeconds"] = String(format: "%.4f", played)
        extra["elapsedMilliseconds"] = String(format: "%.1f", played * 1000.0)
        extra["inference"] = inferredMuted ? "silent" : "ringer-on"
        extra["measuredAt"] = ProbeEnv.iso.string(from: Date())

        return [ProbeItem(
            "focus.ringer.timingInference",
            "Ring/silent switch (timing inference)",
            .partial,
            value: inferredMuted
                ? "likely SILENT — played in \(String(format: "%.0f", played * 1000)) ms of \(String(format: "%.0f", outcome.wavSeconds * 1000)) ms"
                : "likely RINGER ON — played in \(String(format: "%.0f", played * 1000)) ms of \(String(format: "%.0f", outcome.wavSeconds * 1000)) ms",
            detail: "INFERENCE, NOT A STATE READ. Reported as partial on purpose, and it does not overturn the verdict item above — there is still no API for this. Method: synthesize a \(String(format: "%.0f", outcome.wavSeconds * 1000)) ms silent PCM WAV in the temp directory, register it as a system sound, and time how long AudioServicesPlaySystemSoundWithCompletion takes to call back. A device with the ringer on plays the full duration; a silenced device skips playback and calls back almost immediately. The threshold is \(String(format: "%.0f", muteThresholdSeconds * 1000)) ms. Every API used is public (AudioToolbox), nothing is dlopened, and no audible sound is produced — but this is a behavioural side channel rather than a documented query, so App Review might object to shipping it; acceptable here because this build is sideloaded for its owner. KNOWN FAILURE MODES a collector must respect: other audio playing can extend the callback and fake 'ringer on'; a busy main thread can extend it too; the reading is instantaneous and stale the moment the user flips the switch; and it cannot see Do Not Disturb or any Focus, which are entirely separate from the ringer switch. Session state on entry was \(priorCategory.rawValue)/\(priorMode.rawValue) and was restored after the test.",
            extra: extra
        )]
    }

    // ------------------------------------------------------------------
    // 6. Screen Time reachability — one-line check, exact error captured
    // ------------------------------------------------------------------

    static func screenTimeItems() async -> [ProbeItem] {
        #if canImport(FamilyControls)
        var out: [ProbeItem] = []

        let statusText = await FocusProbeScreenTime.statusText()
        out.append(ProbeItem(
            "focus.screentime.authorizationStatus",
            "Screen Time (FamilyControls) authorization status",
            statusText == "approved" ? .ok : (statusText == "denied" ? .denied : .notDetermined),
            value: statusText,
            detail: "FamilyControls imports on this SDK and AuthorizationCenter.shared resolved, which proves the framework is present and weak-linking worked. The status alone is not the answer, though — notDetermined is what an unentitled build reports too. The request below is the real test.",
            extra: ["framework": "FamilyControls", "resolved": "true"]
        ))

        let result = await FocusProbeScreenTime.request()
        if result.ok {
            out.append(ProbeItem(
                "focus.screentime.requestAuthorization",
                "requestAuthorization(for: .individual)",
                .ok,
                value: "SUCCEEDED — Screen Time is reachable at this signing tier",
                detail: "Genuinely surprising and highly consequential if you are reading this: the request did not throw, meaning com.apple.developer.family-controls is in force on this binary. That makes Screen Time data (DeviceActivity reports, ManagedSettings) reachable, which is the single largest closed door in this whole project. Follow-up work is a DeviceActivityReport extension — deliberately NOT built here, since this file is a reachability check only.",
                extra: ["framework": "FamilyControls", "member": "individual", "threw": "false"]
            ))
        } else {
            out.append(ProbeItem(
                "focus.screentime.requestAuthorization",
                "requestAuthorization(for: .individual)",
                .denied,
                value: "failed — \(result.domain.isEmpty ? "unknown domain" : result.domain) code \(result.code)",
                detail: "This is the definitive answer on Screen Time reachability at this signing tier, and the exact error text is the whole point of the item. Without the approval-gated com.apple.developer.family-controls entitlement — requested only in tier2, which is expected to fail to provision — this call MUST fail, so failure here is the predicted result rather than a bug. localizedDescription for FamilyControlsError is frequently the useless 'The operation couldn't be completed', so the NSError domain and code are recorded in extra where they are actually diagnostic. Reference points: code 5 is authorizationCanceled (user dismissed), code 3 is invalidArgument. Full description: \(result.message)",
                extra: [
                    "framework": "FamilyControls",
                    "member": "individual",
                    "threw": "true",
                    "errorDomain": result.domain,
                    "errorCode": result.code,
                    "errorDescription": result.message,
                    "entitlementRequired": "com.apple.developer.family-controls"
                ]
            ))
        }

        out.append(ProbeItem(
            "focus.screentime.scope",
            "Screen Time probing scope",
            .partial,
            value: "reachability only, by design",
            detail: "No DeviceActivity extension is built here. Screen Time usage data is only readable from a DeviceActivityReport extension rendering inside a SwiftUI report scene — the host app can never read the numbers directly, even when authorized. That is a separate build target and out of scope for a single-file probe. This item exists so the boundary is recorded rather than looking like an oversight.",
            extra: ["deviceActivityExtensionBuilt": "false"]
        ))

        return out
        #else
        return [ProbeItem(
            "focus.screentime.authorizationStatus",
            "Screen Time (FamilyControls) authorization status",
            .unavailable,
            value: "FamilyControls does not import",
            detail: "The FamilyControls framework is not importable in this build configuration, so Screen Time is unreachable regardless of entitlements. It is weak-linked in project.yml, so this outcome would indicate an SDK or linkage problem rather than a device limitation."
        )]
        #endif
    }

    // ------------------------------------------------------------------
    // Section summary
    // ------------------------------------------------------------------

    static func summarize(_ items: [ProbeItem]) -> String {
        var t: [ProbeStatus: Int] = [:]
        for i in items { t[i.status, default: 0] += 1 }
        let ok = t[.ok] ?? 0
        let denied = (t[.denied] ?? 0) + (t[.notDetermined] ?? 0)
        let unavailable = t[.unavailable] ?? 0

        let focusLine = items.first { $0.key == "focus.status.isFocused" }?.value ?? "not sampled"
        let authLine = items.first { $0.key == "focus.status.authorizationAfter" }?.value ?? "unknown"
        let ringLine = items.first { $0.key == "focus.ringer.timingInference" }?.value ?? "not measured"

        return "\(items.count) checks — \(ok) returned real data, \(denied) blocked on permission, \(unavailable) unavailable. "
            + "Focus authorization: \(authLine). isFocused: \(focusLine) (reported as four distinct states, because nil-while-authorized and nil-because-unauthorized mean opposite things). "
            + "Ring/silent has NO public API on any iOS through 26 — that question is closed; the timing inference reported here is a behavioural side channel, not a state read: \(ringLine). "
            + "The recommended upgrade for learning WHICH Focus is active is a SetFocusFilterIntent Focus Filter, reported for availability only and deliberately not declared, because declaring one registers this app in every Focus in Settings permanently. "
            + "No backfill window is measured in this section: Focus status, notification settings, and ringer state are all strictly point-in-time with no historical query surface anywhere in these APIs, so there is no oldest-datum figure to report."
    }
}

// MARK: - FamilyControls main-actor bridge

#if canImport(FamilyControls)
/// `AuthorizationCenter` is main-actor bound. Both the status read and the
/// async request live here so the call sites stay non-isolated — note the
/// request cannot go inside `MainActor.run`, whose body is synchronous and
/// cannot `await`.
enum FocusProbeScreenTime {

    @MainActor
    static func statusText() -> String {
        switch AuthorizationCenter.shared.authorizationStatus {
        case .notDetermined: return "notDetermined"
        case .denied:        return "denied"
        case .approved:      return "approved"
        @unknown default:    return "unknown"
        }
    }

    @MainActor
    static func request() async -> (ok: Bool, domain: String, code: String, message: String) {
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
            return (true, "", "", "")
        } catch {
            let ns = error as NSError
            return (false, ns.domain, String(ns.code), String(describing: error))
        }
    }
}
#endif
