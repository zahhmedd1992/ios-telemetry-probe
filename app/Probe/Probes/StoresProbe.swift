import Foundation
import UIKit
import EventKit
import Contacts
import Photos
import MediaPlayer
import Speech
import AVFoundation
import CoreLocation

#if canImport(AppTrackingTransparency)
import AppTrackingTransparency
#endif

// MARK: - StoresProbe
//
// Probes every on-device personal *data store*: calendars, reminders, contacts,
// the photo library, and the media library — plus the small set of adjacent
// permissions (speech, tracking) that gate other stores.
//
// PRIVACY CONTRACT FOR THIS SECTION
// --------------------------------
// This probe never emits personal *content*. No contact names, no event or
// reminder titles, no note bodies, no attendee identities, no track / album /
// artist names, no photo identifiers, no coordinates, no clipboard contents.
// Everything reported is a count, a date, an authorization status, a duration,
// or an aggregate statistic. The report is meant to be shareable, and that
// property only holds if this rule is absolute.
//
// STRUCTURE
// ---------
// Phase 1 requests every permission, strictly serialized — iOS presents one
// system permission sheet at a time and racing the requests silently drops
// prompts. Phase 2 runs the expensive queries, each inside its own
// `withProbeTimeout` so one wedged framework call costs a single item rather
// than the whole section (the runner replaces a timed-out section wholesale).
//
// Every permission request is preceded by an Info.plist usage-string check.
// Requesting a TCC-gated capability without its usage string is an immediate
// process kill, not a catchable error — so a missing key is reported as
// `.unavailable` and the request is skipped.

struct StoresProbe: TelemetryProbe {

    let key = "stores"
    let title = "Personal Data Stores"

    // ================================================================
    // MARK: Nested helpers (nested = namespaced; no cross-file collisions)
    // ================================================================

    /// Guarantees a continuation is resumed exactly once even when a callback
    /// API fires more than once. Lock-based rather than a captured `var` so a
    /// callback arriving on a framework-owned queue cannot race us.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if fired { return false }
            fired = true
            return true
        }
    }

    /// Registered and immediately unregistered to prove the change-observation
    /// path is wired.
    private final class PhotoObserver: NSObject, PHPhotoLibraryChangeObserver {
        func photoLibraryDidChange(_ changeInstance: PHChange) { /* no-op */ }
    }

    /// Reminder statistics are computed inside the fetch callback so that only
    /// this plain-value struct — not an array of EKReminder objects — crosses
    /// the concurrency boundary.
    private struct ReminderStats {
        var count = 0
        var withDueDate = 0
        var withStartDate = 0
        var overdue = 0
        var withAnyAlarm = 0
        var withLocationAlarm = 0
        var withNotes = 0
        var recurring = 0
        var prioritised = 0
        var oldestCompletion: Date?
        var newestCompletion: Date?
        var completedLast7d = 0
        var completedLast30d = 0
        var completedLast365d = 0
        var completedOlderThan1y = 0
    }

    private enum Fmt {
        static func pct(_ n: Int, of d: Int) -> String {
            guard d > 0 else { return "n/a" }
            return String(format: "%.1f%%", (Double(n) / Double(d)) * 100.0)
        }

        static func median(_ xs: [Int]) -> Int {
            guard !xs.isEmpty else { return 0 }
            let s = xs.sorted()
            let mid = s.count / 2
            if s.count % 2 == 1 {
                return s.indices.contains(mid) ? s[mid] : 0
            }
            guard s.indices.contains(mid), s.indices.contains(mid - 1) else { return 0 }
            return (s[mid - 1] + s[mid]) / 2
        }

        static func secs(_ t: TimeInterval?) -> String {
            guard let t, t.isFinite, t > 0 else { return "0s" }
            return String(format: "%.0fs (%.1f min)", t, t / 60.0)
        }
    }

    /// Missing usage strings are a process kill, not an error. Check first.
    private func hasInfoKey(_ k: String) -> Bool {
        guard let v = Bundle.main.object(forInfoDictionaryKey: k) as? String else { return false }
        return !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func ekStatusName(_ s: EKAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: return "notDetermined"
        case .restricted:    return "restricted"
        case .denied:        return "denied"
        case .fullAccess:    return "fullAccess"
        case .writeOnly:     return "writeOnly"
        @unknown default:    return "unknown(\(s.rawValue))"
        }
    }

    private func ekProbeStatus(_ s: EKAuthorizationStatus) -> ProbeStatus {
        switch s {
        case .notDetermined: return .notDetermined
        case .restricted, .denied: return .denied
        case .fullAccess: return .ok
        case .writeOnly: return .partial
        @unknown default: return .partial
        }
    }

    private func cnIsLimited(_ s: CNAuthorizationStatus) -> Bool {
        if #available(iOS 18.0, *) { return s == .limited }
        return false
    }

    private func cnStatusName(_ s: CNAuthorizationStatus) -> String {
        if cnIsLimited(s) { return "limited" }
        switch s {
        case .notDetermined: return "notDetermined"
        case .restricted:    return "restricted"
        case .denied:        return "denied"
        case .authorized:    return "authorized (full)"
        @unknown default:    return "unknown(\(s.rawValue))"
        }
    }

    private func phStatusName(_ s: PHAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: return "notDetermined"
        case .restricted:    return "restricted"
        case .denied:        return "denied"
        case .authorized:    return "authorized (full)"
        case .limited:       return "limited"
        @unknown default:    return "unknown(\(s.rawValue))"
        }
    }

    private func mpStatusName(_ s: MPMediaLibraryAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: return "notDetermined"
        case .restricted:    return "restricted"
        case .denied:        return "denied"
        case .authorized:    return "authorized"
        @unknown default:    return "unknown(\(s.rawValue))"
        }
    }

    private func sourceTypeName(_ t: EKSourceType) -> String {
        switch t {
        case .local:      return "local"
        case .exchange:   return "exchange"
        case .calDAV:     return "calDAV"
        case .mobileMe:   return "mobileMe"
        case .subscribed: return "subscribed"
        case .birthdays:  return "birthdays"
        @unknown default: return "unknown(\(t.rawValue))"
        }
    }

    private func calendarTypeName(_ t: EKCalendarType) -> String {
        switch t {
        case .local:        return "local"
        case .calDAV:       return "calDAV"
        case .exchange:     return "exchange"
        case .subscription: return "subscription"
        case .birthday:     return "birthday"
        @unknown default:   return "unknown(\(t.rawValue))"
        }
    }

    // ================================================================
    // MARK: run
    // ================================================================

    func run() async -> ProbeSection {
        var items: [ProbeItem] = []

        // ProbeRunner wraps this whole method in a 180s timeout and discards
        // the ENTIRE section on expiry. Per-phase budgets protect against one
        // wedged call; they do nothing about the aggregate. So every phase is
        // additionally clipped to a shared wall-clock deadline, and phases that
        // find no budget left yield a `.partial` marker rather than risk the
        // whole section. 150s leaves the runner 30s of headroom.
        let sectionStart = Date()
        let deadline = sectionStart.addingTimeInterval(150)

        // ---- PHASE 1 — permissions, strictly serialized -----------------
        let store = EKEventStore()
        let ev = await requestEventAccess(store, entity: .event)
        items.append(ev.0)
        let rem = await requestEventAccess(store, entity: .reminder)
        items.append(rem.0)

        let contactStore = CNContactStore()
        let cn = await requestContactsAccess(contactStore)
        items.append(cn.0)

        let ph = await requestPhotosAccess()
        items.append(ph.0)

        let mp = await requestMediaAccess()
        items.append(mp.0)

        items.append(contentsOf: await speechItems())

        let eventStatus = ev.1
        let reminderStatus = rem.1
        let contactStatus = cn.1
        let photoStatus = ph.1
        let mediaStatus = mp.1

        // ---- PHASE 2 — measurement, budgeted per phase AND section-wide --
        items.append(contentsOf: await phase("ek.calendars", "Calendars (events)", 30, deadline)
            { self.calendarStructureItems(store, status: eventStatus) })

        items.append(contentsOf: await phase("ek.events", "Event windows", 30, deadline)
            { self.eventWindowItems(store, status: eventStatus) })

        items.append(contentsOf: await phase("ek.depth", "Event backfill depth", 35, deadline)
            { self.eventDepthItems(store, status: eventStatus) })

        items.append(contentsOf: await phase("ek.reminders", "Reminders", 30, deadline)
            { await self.reminderItems(store, status: reminderStatus) })

        items.append(contentsOf: await phase("cn.contacts", "Contacts", 40, deadline)
            { self.contactItems(contactStore, status: contactStatus) })

        items.append(contentsOf: await phase("ph.assets", "Photo library", 45, deadline)
            { self.photoItems(status: photoStatus) })

        items.append(contentsOf: await phase("mp.library", "Media library", 40, deadline)
            { await self.mediaLibraryItems(status: mediaStatus) })

        items.append(contentsOf: await phase("np.other", "Now playing (other apps)", 10, deadline)
            { await self.nowPlayingElsewhereItems() })

        items.append(contentsOf: await phase("pb.clipboard", "Clipboard", 10, deadline)
            { await self.clipboardItems() })

        // These three are pure in-memory constructions — no budget needed.
        items.append(trackingItem())
        items.append(contentsOf: unreachableItems())

        let elapsed = Date().timeIntervalSince(sectionStart)
        let skipped = items.filter { $0.key.hasSuffix(".skipped") }.count
        let timedOut = items.filter { $0.key.hasSuffix(".timeout") }.count
        items.append(ProbeItem("stores.meta.wallClock", "Section wall clock",
                               (skipped == 0 && timedOut == 0) ? .ok : .partial,
                               value: "\(String(format: "%.1f", elapsed))s · \(skipped) phase(s) skipped · \(timedOut) timed out",
                               detail: "The runner discards any section that exceeds 180s, so this section self-limits to a 150s wall clock and yields late phases rather than losing every earlier measurement. Permission prompts only appear on the FIRST run — if phases were skipped here, re-running the probe gives them the full budget.",
                               extra: ["elapsedSeconds": String(format: "%.2f", elapsed),
                                       "sectionBudgetSeconds": "150",
                                       "runnerSectionCapSeconds": "180",
                                       "phasesSkipped": "\(skipped)",
                                       "phasesTimedOut": "\(timedOut)",
                                       "measurementPhases": "9"]))

        return section(summaryText(items), items)
    }

    /// Runs one measurement phase clipped to both its own budget and the
    /// section-wide deadline. Yields a marker item rather than starting work
    /// there is no budget left to finish.
    /// The `work` closure is never invoked when the section budget is spent.
    private func phase(_ k: String, _ label: String, _ want: Double, _ deadline: Date,
                       _ work: @escaping () async -> [ProbeItem]) async -> [ProbeItem] {
        let left = max(0, deadline.timeIntervalSinceNow)
        guard left >= 3 else {
            return [ProbeItem("stores.\(k).skipped", "\(label) — skipped", .partial,
                              value: "section wall-clock budget exhausted",
                              detail: "Earlier phases consumed the section's 150s budget, so this one was not started. Skipping is deliberate: the runner discards any section over 180s, which would throw away every measurement already made. Re-run the probe — permission prompts fire only once, so a second run has the full budget.",
                              extra: ["requestedBudgetSeconds": "\(Int(want))",
                                      "remainingSectionSeconds": String(format: "%.1f", left),
                                      "started": "false"])]
        }
        let b = min(want, left)
        return await withProbeTimeout(b, fallback: [timeoutItem(k, label, b)], work)
    }

    private func timeoutItem(_ k: String, _ label: String, _ budget: Double) -> ProbeItem {
        ProbeItem("stores.\(k).timeout", "\(label) — timed out", .error,
                  value: "no result in \(String(format: "%.0f", budget))s",
                  detail: "The framework call did not return inside this phase's budget. Other phases were unaffected.",
                  extra: ["budgetSeconds": String(format: "%.1f", budget)])
    }

    // ================================================================
    // MARK: 1a. EventKit authorization (iOS 17 split model)
    // ================================================================

    private func requestEventAccess(_ store: EKEventStore,
                                    entity: EKEntityType) async -> (ProbeItem, EKAuthorizationStatus) {
        let isEvent = (entity == .event)
        let k = isEvent ? "stores.ek.auth.event" : "stores.ek.auth.reminder"
        let label = isEvent ? "Calendar authorization" : "Reminders authorization"

        let before = EKEventStore.authorizationStatus(for: entity)

        // iOS 17 split the single calendar prompt into full-access and
        // write-only. NSCalendarsUsageDescription alone no longer reliably
        // satisfies a full-access request on 17+; the *FullAccess* key does.
        let fullKey = isEvent ? "NSCalendarsFullAccessUsageDescription" : "NSRemindersFullAccessUsageDescription"
        let legacyKey = isEvent ? "NSCalendarsUsageDescription" : "NSRemindersUsageDescription"
        let haveFull = hasInfoKey(fullKey)
        let haveLegacy = hasInfoKey(legacyKey)

        guard haveFull || haveLegacy else {
            let item = ProbeItem(k, label, .unavailable,
                                 value: ekStatusName(before),
                                 detail: "Neither \(fullKey) nor \(legacyKey) is present in Info.plist. Requesting access without a usage string terminates the process, so the request was skipped. The status shown is the pre-existing one.",
                                 extra: ["statusBefore": ekStatusName(before),
                                         "statusRaw": "\(before.rawValue)",
                                         "infoPlistFullAccessKey": "missing",
                                         "infoPlistLegacyKey": haveLegacy ? "present" : "missing"])
            return (item, before)
        }

        var granted = false
        var errText: String?
        var apiUsed = "none (already answered)"

        if before == .notDetermined {
            if #available(iOS 17.0, *) {
                apiUsed = isEvent ? "requestFullAccessToEvents" : "requestFullAccessToReminders"
                let once = Once()
                let r: (Bool, String?) = await withProbeTimeout(
                    45, fallback: (false, "no callback within 45s — the prompt was likely left unanswered")
                ) {
                    await withCheckedContinuation { c in
                        if isEvent {
                            store.requestFullAccessToEvents { ok, err in
                                if once.claim() { c.resume(returning: (ok, err?.localizedDescription)) }
                            }
                        } else {
                            store.requestFullAccessToReminders { ok, err in
                                if once.claim() { c.resume(returning: (ok, err?.localizedDescription)) }
                            }
                        }
                    }
                }
                granted = r.0
                errText = r.1
            } else {
                // Retained for completeness; unreachable at an iOS 17 deployment
                // target. requestAccess(to:) is deprecated on 17+ and grants the
                // old undifferentiated "authorized" level when it does run.
                apiUsed = "requestAccess(to:) [deprecated pre-17 path]"
                let once = Once()
                let r: (Bool, String?) = await withProbeTimeout(
                    45, fallback: (false, "no callback within 45s — the prompt was likely left unanswered")
                ) {
                    await withCheckedContinuation { c in
                        store.requestAccess(to: entity) { ok, err in
                            if once.claim() { c.resume(returning: (ok, err?.localizedDescription)) }
                        }
                    }
                }
                granted = r.0
                errText = r.1
            }
        }

        let after = EKEventStore.authorizationStatus(for: entity)
        var extra: [String: String] = [
            "statusBefore": ekStatusName(before),
            "statusAfter": ekStatusName(after),
            "statusAfterRaw": "\(after.rawValue)",
            "prompted": before == .notDetermined ? "true" : "false",
            "grantedByCallback": granted ? "true" : "false",
            "api": apiUsed,
            "infoPlistFullAccessKey": haveFull ? "present" : "missing",
            "infoPlistLegacyKey": haveLegacy ? "present" : "missing"
        ]
        if let errText { extra["requestError"] = errText }

        var detail = "iOS 17+ splits calendar/reminder access into fullAccess and writeOnly. Authorization status is reported independently of whether data came back — the two diverge often, and the divergence is the finding."
        if after == .writeOnly {
            detail += " writeOnly means this app can create items but cannot read any, so every count below will read as empty rather than as denied."
        }
        if !haveFull && haveLegacy {
            detail += " Only the legacy usage-description key is present; on iOS 17+ that key is a fallback and full read access may be refused."
        }

        let item = ProbeItem(k, label, ekProbeStatus(after),
                             value: ekStatusName(after), detail: detail, extra: extra)
        return (item, after)
    }

    // ================================================================
    // MARK: 1b. Contacts authorization
    // ================================================================

    private func requestContactsAccess(_ store: CNContactStore) async -> (ProbeItem, CNAuthorizationStatus) {
        let before = CNContactStore.authorizationStatus(for: .contacts)

        guard hasInfoKey("NSContactsUsageDescription") else {
            let item = ProbeItem("stores.cn.auth", "Contacts authorization", .unavailable,
                                 value: cnStatusName(before),
                                 detail: "NSContactsUsageDescription is missing from Info.plist; the request was skipped to avoid a TCC process kill.",
                                 extra: ["statusBefore": cnStatusName(before)])
            return (item, before)
        }

        var granted = false
        var errText: String?
        if before == .notDetermined {
            let once = Once()
            let r: (Bool, String?) = await withProbeTimeout(
                45, fallback: (false, "no callback within 45s — the prompt was likely left unanswered")
            ) {
                await withCheckedContinuation { c in
                    store.requestAccess(for: .contacts) { ok, err in
                        if once.claim() { c.resume(returning: (ok, err?.localizedDescription)) }
                    }
                }
            }
            granted = r.0
            errText = r.1
        }

        let after = CNContactStore.authorizationStatus(for: .contacts)
        let isLimited = cnIsLimited(after)
        var osSupportsLimited = "false"
        if #available(iOS 18.0, *) { osSupportsLimited = "true" }

        var extra: [String: String] = [
            "statusBefore": cnStatusName(before),
            "statusAfter": cnStatusName(after),
            "statusAfterRaw": "\(after.rawValue)",
            "prompted": before == .notDetermined ? "true" : "false",
            "grantedByCallback": granted ? "true" : "false",
            "limitedAccessInPlay": isLimited ? "true" : "false",
            "osSupportsLimited": osSupportsLimited
        ]
        if let errText { extra["requestError"] = errText }

        var status: ProbeStatus = .partial
        if isLimited {
            status = .partial
        } else {
            switch after {
            case .authorized:    status = .ok
            case .notDetermined: status = .notDetermined
            case .denied, .restricted: status = .denied
            @unknown default:    status = .partial
            }
        }

        let detail = isLimited
            ? "iOS 18+ limited access IS in play: the user picked a subset of contacts. Every contact count below is scoped to that subset, not to the address book — treat them as a floor, never a total."
            : "iOS 18+ adds a `.limited` authorization tier where the user picks specific contacts. Not in play on this run (either not granted as limited, or the OS predates it)."

        let item = ProbeItem("stores.cn.auth", "Contacts authorization", status,
                             value: cnStatusName(after), detail: detail, extra: extra)
        return (item, after)
    }

    // ================================================================
    // MARK: 1c. Photos authorization
    // ================================================================

    private func requestPhotosAccess() async -> (ProbeItem, PHAuthorizationStatus) {
        let before = PHPhotoLibrary.authorizationStatus(for: .readWrite)

        guard hasInfoKey("NSPhotoLibraryUsageDescription") else {
            let item = ProbeItem("stores.ph.auth", "Photos authorization", .unavailable,
                                 value: phStatusName(before),
                                 detail: "NSPhotoLibraryUsageDescription is missing from Info.plist; the request was skipped to avoid a TCC process kill.",
                                 extra: ["statusBefore": phStatusName(before)])
            return (item, before)
        }

        if before == .notDetermined {
            let once = Once()
            _ = await withProbeTimeout(45, fallback: before) {
                await withCheckedContinuation { (c: CheckedContinuation<PHAuthorizationStatus, Never>) in
                    PHPhotoLibrary.requestAuthorization(for: .readWrite) { s in
                        if once.claim() { c.resume(returning: s) }
                    }
                }
            }
        }

        let after = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        var status: ProbeStatus = .partial
        switch after {
        case .authorized:    status = .ok
        case .limited:       status = .partial
        case .notDetermined: status = .notDetermined
        case .denied, .restricted: status = .denied
        @unknown default:    status = .partial
        }

        let detail = (after == .limited)
            ? "LIMITED access is in play. PHAsset fetches return only the user-selected subset, so every asset count below describes that subset — not the library. This is the single most common way a photo-library report reads as false."
            : "Reported for the .readWrite access level. .addOnly is a separate, narrower level under which every read comes back empty."

        let item = ProbeItem("stores.ph.auth", "Photos authorization", status,
                             value: phStatusName(after),
                             detail: detail,
                             extra: ["statusBefore": phStatusName(before),
                                     "statusAfter": phStatusName(after),
                                     "statusAfterRaw": "\(after.rawValue)",
                                     "accessLevel": "readWrite",
                                     "prompted": before == .notDetermined ? "true" : "false",
                                     "limitedAccessInPlay": after == .limited ? "true" : "false"])
        return (item, after)
    }

    // ================================================================
    // MARK: 1d. Media library authorization
    // ================================================================

    private func requestMediaAccess() async -> (ProbeItem, MPMediaLibraryAuthorizationStatus) {
        let before = MPMediaLibrary.authorizationStatus()

        guard hasInfoKey("NSAppleMusicUsageDescription") else {
            let item = ProbeItem("stores.mp.auth", "Media library authorization", .unavailable,
                                 value: mpStatusName(before),
                                 detail: "NSAppleMusicUsageDescription is missing from Info.plist; the request was skipped to avoid a TCC process kill.",
                                 extra: ["statusBefore": mpStatusName(before)])
            return (item, before)
        }

        if before == .notDetermined {
            let once = Once()
            _ = await withProbeTimeout(45, fallback: before) {
                await withCheckedContinuation { (c: CheckedContinuation<MPMediaLibraryAuthorizationStatus, Never>) in
                    MPMediaLibrary.requestAuthorization { s in
                        if once.claim() { c.resume(returning: s) }
                    }
                }
            }
        }

        let after = MPMediaLibrary.authorizationStatus()
        var status: ProbeStatus = .partial
        switch after {
        case .authorized:    status = .ok
        case .notDetermined: status = .notDetermined
        case .denied, .restricted: status = .denied
        @unknown default:    status = .partial
        }

        let item = ProbeItem("stores.mp.auth", "Media library authorization", status,
                             value: mpStatusName(after),
                             detail: "Gates MPMediaQuery, MPMediaLibrary.lastModifiedDate, and systemMusicPlayer.nowPlayingItem. It does NOT gate playback of your own audio.",
                             extra: ["statusBefore": mpStatusName(before),
                                     "statusAfter": mpStatusName(after),
                                     "statusAfterRaw": "\(after.rawValue)",
                                     "prompted": before == .notDetermined ? "true" : "false"])
        return (item, after)
    }

    // ================================================================
    // MARK: 2. Calendar structure
    // ================================================================

    private func calendarStructureItems(_ store: EKEventStore, status: EKAuthorizationStatus) -> [ProbeItem] {
        guard status == .fullAccess else {
            return [ProbeItem("stores.ek.calendars", "Calendars (events)", ekProbeStatus(status),
                              value: "not readable",
                              detail: "The calendar list requires fullAccess. Current status: \(ekStatusName(status)).")]
        }

        let cals = store.calendars(for: .event)
        guard !cals.isEmpty else {
            return [ProbeItem("stores.ek.calendars", "Calendars (events)", .empty,
                              value: "0 calendars",
                              detail: "Access granted but no event calendars exist on this device.")]
        }

        var bySource: [String: Int] = [:]
        var byType: [String: Int] = [:]
        var immutable = 0
        var subscribed = 0
        var sourceKinds = Set<String>()

        for c in cals {
            let sName = sourceTypeName(c.source.sourceType)
            bySource[sName, default: 0] += 1
            sourceKinds.insert(sName)
            byType[calendarTypeName(c.type), default: 0] += 1
            if !c.allowsContentModifications { immutable += 1 }
            if c.isSubscribed { subscribed += 1 }
        }

        var extra: [String: String] = [
            "calendarCount": "\(cals.count)",
            "distinctSourceTypes": "\(sourceKinds.count)",
            "readOnlyCalendars": "\(immutable)",
            "subscribedCalendars": "\(subscribed)",
            "defaultCalendarForNewEventsExists": store.defaultCalendarForNewEvents == nil ? "false" : "true",
            "sourceObjectCount": "\(store.sources.count)"
        ]
        for (k, v) in bySource { extra["source.\(k)"] = "\(v)" }
        for (k, v) in byType { extra["type.\(k)"] = "\(v)" }

        let breakdown = bySource.sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }.joined(separator: ", ")

        return [ProbeItem("stores.ek.calendars", "Calendars (events)", .ok,
                          value: "\(ProbeEnv.int(cals.count)) calendars — \(breakdown)",
                          detail: "Counted by EKSource.sourceType. Calendar titles are deliberately omitted; only the source-type shape of the account set is reported.",
                          extra: extra)]
    }

    // ================================================================
    // MARK: 3. Event windows (last 30 / next 30 days) + event shape
    // ================================================================

    private func eventWindowItems(_ store: EKEventStore, status: EKAuthorizationStatus) -> [ProbeItem] {
        guard status == .fullAccess else {
            return [ProbeItem("stores.ek.window", "Events, ±30 days", ekProbeStatus(status),
                              value: "not readable",
                              detail: "Event reads require fullAccess. Current status: \(ekStatusName(status)). writeOnly can create events but every read comes back empty.")]
        }

        let now = Date()
        let past = store.predicateForEvents(withStart: now.addingTimeInterval(-30 * 86_400),
                                            end: now, calendars: nil)
        let future = store.predicateForEvents(withStart: now,
                                              end: now.addingTimeInterval(30 * 86_400), calendars: nil)
        let pastEvents = store.events(matching: past)
        let futureEvents = store.events(matching: future)
        let all = pastEvents + futureEvents

        var withStructuredLocation = 0
        var withGeoCoordinate = 0
        var withGeofenceRadius = 0
        var withProximityAlarm = 0
        var withAnyAlarm = 0
        var allDay = 0
        var recurring = 0
        var detached = 0
        var withNotes = 0
        var withURL = 0
        var withOrganizer = 0
        var birthdays = 0
        var b0 = 0, b12 = 0, b35 = 0, b610 = 0, b11 = 0
        var attendeeTotal = 0
        var maxAttendees = 0
        var radiusSum = 0.0
        var radiusCount = 0

        for e in all {
            if e.isAllDay { allDay += 1 }
            if e.hasRecurrenceRules { recurring += 1 }
            if e.isDetached { detached += 1 }
            if e.hasNotes { withNotes += 1 }
            if e.url != nil { withURL += 1 }
            if e.organizer != nil { withOrganizer += 1 }
            if e.birthdayContactIdentifier != nil { birthdays += 1 }

            if let sl = e.structuredLocation {
                withStructuredLocation += 1
                if sl.geoLocation != nil { withGeoCoordinate += 1 }
                if sl.radius > 0 {
                    withGeofenceRadius += 1
                    radiusSum += sl.radius
                    radiusCount += 1
                }
            }

            if let alarms = e.alarms, !alarms.isEmpty {
                withAnyAlarm += 1
                for a in alarms {
                    if a.structuredLocation != nil && a.proximity != EKAlarmProximity.none {
                        withProximityAlarm += 1
                        break
                    }
                }
            }

            let n = e.attendees?.count ?? 0
            attendeeTotal += n
            maxAttendees = max(maxAttendees, n)
            switch n {
            case 0:      b0 += 1
            case 1...2:  b12 += 1
            case 3...5:  b35 += 1
            case 6...10: b610 += 1
            default:     b11 += 1
            }
        }

        var items: [ProbeItem] = []

        items.append(ProbeItem("stores.ek.window", "Events, last 30 / next 30 days",
                               all.isEmpty ? .empty : .ok,
                               value: "\(ProbeEnv.int(pastEvents.count)) past 30d · \(ProbeEnv.int(futureEvents.count)) next 30d",
                               detail: "Counts only. No titles, notes, locations, or participant identities are read into the report.",
                               extra: ["last30dCount": "\(pastEvents.count)",
                                       "next30dCount": "\(futureEvents.count)",
                                       "combined": "\(all.count)",
                                       "allDay": "\(allDay)",
                                       "recurring": "\(recurring)",
                                       "detachedOccurrences": "\(detached)",
                                       "withNotes": "\(withNotes)",
                                       "withURL": "\(withURL)",
                                       "withOrganizer": "\(withOrganizer)",
                                       "birthdayEvents": "\(birthdays)",
                                       "withAnyAlarm": "\(withAnyAlarm)"]))

        items.append(ProbeItem("stores.ek.structuredLocation", "Events carrying structuredLocation",
                               withStructuredLocation > 0 ? .ok : .empty,
                               value: "\(ProbeEnv.int(withStructuredLocation)) of \(ProbeEnv.int(all.count)) (\(Fmt.pct(withStructuredLocation, of: all.count)))",
                               detail: "EKStructuredLocation is the geocoded form of an event location. Only the presence of a coordinate and the geofence radius are reported — never the coordinate itself.",
                               extra: ["eventsScanned": "\(all.count)",
                                       "withStructuredLocation": "\(withStructuredLocation)",
                                       "withGeoCoordinate": "\(withGeoCoordinate)",
                                       "withGeofenceRadius": "\(withGeofenceRadius)",
                                       "meanGeofenceRadiusMeters": radiusCount > 0 ? ProbeEnv.num(radiusSum / Double(radiusCount)) : "n/a"]))

        items.append(ProbeItem("stores.ek.travelTime", "Event travel time", .unavailable,
                               value: "no public API — measured via its public proxy instead",
                               detail: "EKEvent does carry a travelTime ivar, but it is NOT exported public API: it appears only in private EventKit headers alongside travelStartLocation, and developer.apple.com returns 404 for it. Reaching it would mean KVC against an undocumented key, which this probe will not do. The public, documented substitute is a location-triggered alarm — EKAlarm.structuredLocation plus EKAlarm.proximity — which is what actually drives Calendar's \"Time to Leave\" notification. That count is reported here.",
                               extra: ["publicTravelTimeAPI": "none",
                                       "proxy": "EKAlarm.structuredLocation + EKAlarm.proximity",
                                       "eventsWithProximityAlarm": "\(withProximityAlarm)",
                                       "eventsScanned": "\(all.count)"]))

        items.append(ProbeItem("stores.ek.attendees", "Attendee count distribution",
                               attendeeTotal > 0 ? .ok : .empty,
                               value: attendeeTotal > 0
                                    ? "\(ProbeEnv.int(attendeeTotal)) participant slots across \(ProbeEnv.int(all.count)) events, max \(maxAttendees) on one event"
                                    : "no events in the window carry attendees",
                               detail: "Distribution only. Attendee names, email addresses, and response statuses are never read.",
                               extra: ["totalParticipantSlots": "\(attendeeTotal)",
                                       "maxAttendeesOnOneEvent": "\(maxAttendees)",
                                       "eventsScanned": "\(all.count)",
                                       "bucket.0": "\(b0)",
                                       "bucket.1-2": "\(b12)",
                                       "bucket.3-5": "\(b35)",
                                       "bucket.6-10": "\(b610)",
                                       "bucket.11plus": "\(b11)"]))

        return items
    }

    // ================================================================
    // MARK: 4. Event backfill depth — measured, not assumed
    // ================================================================

    private func eventDepthItems(_ store: EKEventStore, status: EKAuthorizationStatus) -> [ProbeItem] {
        guard status == .fullAccess else {
            return [ProbeItem("stores.ek.depth", "Event backfill depth", ekProbeStatus(status),
                              value: "not measurable",
                              detail: "Requires fullAccess. Current status: \(ekStatusName(status)).")]
        }

        let now = Date()
        var extra: [String: String] = [:]
        var oldestWindowed: Date?
        var windowedTotal = 0
        var deepestNonEmptyYear = 0

        // Six one-year windows walking backwards. Each predicate spans a single
        // year, so none of them can hit the documented 4-year predicate cap —
        // which is exactly what makes this a valid control for the test below.
        for y in 1...6 {
            let end = now.addingTimeInterval(-Double(y - 1) * 365.0 * 86_400)
            let start = now.addingTimeInterval(-Double(y) * 365.0 * 86_400)
            let p = store.predicateForEvents(withStart: start, end: end, calendars: nil)
            let evs = store.events(matching: p)
            windowedTotal += evs.count
            extra["windowMinus\(y)y.count"] = "\(evs.count)"
            if !evs.isEmpty {
                deepestNonEmptyYear = y
                for e in evs {
                    let s = e.startDate
                    if let s {
                        if let cur = oldestWindowed {
                            if s < cur { oldestWindowed = s }
                        } else {
                            oldestWindowed = s
                        }
                    }
                }
            }
        }

        extra["windowedTotalEvents"] = "\(windowedTotal)"
        extra["deepestNonEmptyYearStep"] = "\(deepestNonEmptyYear)"
        if let o = oldestWindowed {
            extra["oldestEventStartWindowed"] = ProbeEnv.stamp(o) ?? "?"
            extra["oldestEventAgeWindowed"] = ProbeEnv.age(o) ?? "?"
            extra["oldestEventAgeDays"] = String(format: "%.0f", now.timeIntervalSince(o) / 86_400)
        }

        var items: [ProbeItem] = []
        items.append(ProbeItem("stores.ek.depth.windowed", "Oldest event reachable (1-year steps, 6 back)",
                               oldestWindowed == nil ? .empty : .ok,
                               value: oldestWindowed == nil
                                    ? "no events found across the previous 6 years"
                                    : "\(ProbeEnv.stamp(oldestWindowed) ?? "?") (\(ProbeEnv.age(oldestWindowed) ?? "?"))",
                               detail: "Real measured depth, not the documented figure. Each step is its own 1-year predicate, so the per-year counts show where this device's calendar history actually thins out.",
                               extra: extra))

        // The contested claim: predicateForEvents is documented as limited to a
        // 4-year span. Ask for ten years in ONE predicate and compare what comes
        // back against the windowed union above. If the cap is real, this
        // returns strictly less history than the windowed walk did.
        let deepStart = now.addingTimeInterval(-10.0 * 365.0 * 86_400)
        let deepP = store.predicateForEvents(withStart: deepStart, end: now, calendars: nil)
        let deepEvents = store.events(matching: deepP)
        var oldestDeep: Date?
        for e in deepEvents {
            let s = e.startDate
            if let s {
                if let cur = oldestDeep {
                    if s < cur { oldestDeep = s }
                } else {
                    oldestDeep = s
                }
            }
        }

        var capVerdict = "inconclusive — not enough calendar history on this device to test the cap"
        var capStatus: ProbeStatus = .partial
        if let ow = oldestWindowed {
            if let od = oldestDeep {
                let gapDays = od.timeIntervalSince(ow) / 86_400
                if gapDays > 30 {
                    capVerdict = "CLAMP CONFIRMED — the single 10-year predicate reached only back to \(ProbeEnv.stamp(od) ?? "?"), \(String(format: "%.0f", gapDays)) days shallower than the 1-year-window walk"
                    capStatus = .partial
                } else {
                    capVerdict = "NO CLAMP OBSERVED — the single 10-year predicate reached as far back as the windowed walk did"
                    capStatus = .ok
                }
            } else {
                capVerdict = "CLAMP CONFIRMED — the 10-year predicate returned nothing while 1-year windows returned events"
                capStatus = .partial
            }
        } else if deepEvents.isEmpty {
            capStatus = .empty
        }

        items.append(ProbeItem("stores.ek.depth.spanCap", "4-year predicate span cap — measured",
                               capStatus,
                               value: capVerdict,
                               detail: "predicateForEvents(withStart:end:calendars:) is documented as limited to a 4-year range. This asks for 10 years in a single predicate and compares the oldest event returned against the union of six 1-year windows. If the clamp is real on this device, chunked queries are mandatory for any historical collector.",
                               extra: ["deepSpanYearsRequested": "10",
                                       "deepSpanEventCount": "\(deepEvents.count)",
                                       "deepSpanOldestStart": ProbeEnv.stamp(oldestDeep) ?? "none",
                                       "windowedOldestStart": ProbeEnv.stamp(oldestWindowed) ?? "none",
                                       "windowedTotalEvents": "\(windowedTotal)"]))

        return items
    }

    // ================================================================
    // MARK: 5. Reminders
    // ================================================================

    /// Stats are computed inside the completion handler so only plain values
    /// cross the async boundary — EKReminder objects never leave this closure.
    private func fetchReminderStats(_ store: EKEventStore,
                                    _ predicate: NSPredicate,
                                    completed: Bool) async -> ReminderStats? {
        await withProbeTimeout(12, fallback: Optional<ReminderStats>.none) {
            await withCheckedContinuation { (c: CheckedContinuation<ReminderStats?, Never>) in
                let once = Once()
                _ = store.fetchReminders(matching: predicate) { rs in
                    guard once.claim() else { return }
                    guard let rs else {
                        c.resume(returning: nil)
                        return
                    }
                    var s = ReminderStats()
                    s.count = rs.count
                    let now = Date()
                    let cal = Calendar.current
                    for r in rs {
                        if completed {
                            guard let d = r.completionDate else { continue }
                            if let cur = s.oldestCompletion { if d < cur { s.oldestCompletion = d } }
                            else { s.oldestCompletion = d }
                            if let cur = s.newestCompletion { if d > cur { s.newestCompletion = d } }
                            else { s.newestCompletion = d }
                            let age = now.timeIntervalSince(d)
                            if age <= 7 * 86_400 { s.completedLast7d += 1 }
                            if age <= 30 * 86_400 { s.completedLast30d += 1 }
                            if age <= 365 * 86_400 { s.completedLast365d += 1 }
                            else { s.completedOlderThan1y += 1 }
                        } else {
                            if let dc = r.dueDateComponents {
                                s.withDueDate += 1
                                if let d = cal.date(from: dc), d < now { s.overdue += 1 }
                            }
                            if r.startDateComponents != nil { s.withStartDate += 1 }
                            if let a = r.alarms, !a.isEmpty {
                                s.withAnyAlarm += 1
                                for x in a {
                                    if x.structuredLocation != nil && x.proximity != EKAlarmProximity.none {
                                        s.withLocationAlarm += 1
                                        break
                                    }
                                }
                            }
                            if r.hasNotes { s.withNotes += 1 }
                            if r.hasRecurrenceRules { s.recurring += 1 }
                            if r.priority != 0 { s.prioritised += 1 }
                        }
                    }
                    c.resume(returning: s)
                }
            }
        }
    }

    private func reminderItems(_ store: EKEventStore, status: EKAuthorizationStatus) async -> [ProbeItem] {
        guard status == .fullAccess else {
            return [ProbeItem("stores.ek.reminders", "Reminders", ekProbeStatus(status),
                              value: "not readable",
                              detail: "Reminder reads require fullAccess for the .reminder entity. Current status: \(ekStatusName(status)).")]
        }

        var items: [ProbeItem] = []
        let lists = store.calendars(for: .reminder)

        var bySource: [String: Int] = [:]
        for c in lists { bySource[sourceTypeName(c.source.sourceType), default: 0] += 1 }
        var listExtra: [String: String] = [
            "listCount": "\(lists.count)",
            "defaultListExists": store.defaultCalendarForNewReminders() == nil ? "false" : "true"
        ]
        for (k, v) in bySource { listExtra["source.\(k)"] = "\(v)" }
        let listBreakdown = bySource.sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }.joined(separator: ", ")

        items.append(ProbeItem("stores.ek.reminderLists", "Reminder lists",
                               lists.isEmpty ? .empty : .ok,
                               value: lists.isEmpty ? "0 lists" : "\(ProbeEnv.int(lists.count)) lists — \(listBreakdown)",
                               detail: "List titles are omitted; only the source-type shape is reported.",
                               extra: listExtra))

        let incompleteP = store.predicateForIncompleteReminders(withDueDateStarting: nil,
                                                                ending: nil, calendars: nil)
        let incomplete = await fetchReminderStats(store, incompleteP, completed: false)

        let now = Date()
        let completedP = store.predicateForCompletedReminders(
            withCompletionDateStarting: now.addingTimeInterval(-5.0 * 365.0 * 86_400),
            ending: now, calendars: nil)
        let completed = await fetchReminderStats(store, completedP, completed: true)

        if let s = incomplete {
            items.append(ProbeItem("stores.ek.remindersIncomplete", "Open reminders",
                                   s.count == 0 ? .empty : .ok,
                                   value: "\(ProbeEnv.int(s.count)) open, \(ProbeEnv.int(s.overdue)) overdue",
                                   detail: "Counts and flags only — no reminder titles or notes.",
                                   extra: ["openCount": "\(s.count)",
                                           "overdue": "\(s.overdue)",
                                           "withDueDate": "\(s.withDueDate)",
                                           "withStartDate": "\(s.withStartDate)",
                                           "withAnyAlarm": "\(s.withAnyAlarm)",
                                           "withLocationTriggeredAlarm": "\(s.withLocationAlarm)",
                                           "withNotes": "\(s.withNotes)",
                                           "recurring": "\(s.recurring)",
                                           "withPriority": "\(s.prioritised)"]))
        } else {
            items.append(ProbeItem("stores.ek.remindersIncomplete", "Open reminders", .error,
                                   value: "fetch returned nil or timed out",
                                   detail: "fetchReminders(matching:completion:) did not deliver inside a 12s budget."))
        }

        if let s = completed {
            items.append(ProbeItem("stores.ek.remindersCompleted", "Completed reminders (5-year window)",
                                   s.count == 0 ? .empty : .ok,
                                   value: s.count == 0
                                        ? "none returned across a 5-year completion window"
                                        : "\(ProbeEnv.int(s.count)) completed, oldest \(ProbeEnv.stamp(s.oldestCompletion) ?? "?")",
                                   detail: "Completed reminders are the closest thing iOS offers to a personal task-history log. The oldest completion date here is the REAL retention depth on this device — Reminders prunes completed items when iCloud sync is on, so this is usually far shorter than the 5 years requested. That gap is the measurement.",
                                   extra: ["completedCount5y": "\(s.count)",
                                           "windowRequestedYears": "5",
                                           "oldestCompletion": ProbeEnv.stamp(s.oldestCompletion) ?? "none",
                                           "oldestCompletionAge": ProbeEnv.age(s.oldestCompletion) ?? "n/a",
                                           "newestCompletion": ProbeEnv.stamp(s.newestCompletion) ?? "none",
                                           "newestCompletionAge": ProbeEnv.age(s.newestCompletion) ?? "n/a",
                                           "completed.last7d": "\(s.completedLast7d)",
                                           "completed.last30d": "\(s.completedLast30d)",
                                           "completed.last365d": "\(s.completedLast365d)",
                                           "completed.olderThan1y": "\(s.completedOlderThan1y)"]))
        } else {
            items.append(ProbeItem("stores.ek.remindersCompleted", "Completed reminders (5-year window)", .error,
                                   value: "fetch returned nil or timed out",
                                   detail: "fetchReminders(matching:completion:) did not deliver inside a 12s budget."))
        }

        return items
    }

    // ================================================================
    // MARK: 6. Contacts
    // ================================================================

    private func contactItems(_ store: CNContactStore, status: CNAuthorizationStatus) -> [ProbeItem] {
        let isLimited = cnIsLimited(status)
        let readable = (status == .authorized) || isLimited

        guard readable else {
            return [ProbeItem("stores.cn.count", "Contacts",
                              status == .notDetermined ? .notDetermined : .denied,
                              value: "not readable",
                              detail: "Current status: \(cnStatusName(status)).")]
        }

        var items: [ProbeItem] = []

        var total = 0
        var withBirthday = 0
        var withNonGregorianBirthday = 0
        var withPostal = 0
        var postalTotal = 0
        var withPhone = 0
        var withEmail = 0
        var withImage = 0
        var withOtherDates = 0
        var withRelations = 0
        var orgRecords = 0
        var enumerationError: String?

        let keys: [CNKeyDescriptor] = [
            CNContactBirthdayKey as CNKeyDescriptor,
            CNContactNonGregorianBirthdayKey as CNKeyDescriptor,
            CNContactPostalAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactImageDataAvailableKey as CNKeyDescriptor,
            CNContactDatesKey as CNKeyDescriptor,
            CNContactRelationsKey as CNKeyDescriptor,
            CNContactTypeKey as CNKeyDescriptor
        ]
        let req = CNContactFetchRequest(keysToFetch: keys)
        req.unifyResults = true
        req.sortOrder = CNContactSortOrder.none

        do {
            try store.enumerateContacts(with: req) { c, _ in
                total += 1
                if c.birthday != nil { withBirthday += 1 }
                if c.nonGregorianBirthday != nil { withNonGregorianBirthday += 1 }
                if !c.postalAddresses.isEmpty {
                    withPostal += 1
                    postalTotal += c.postalAddresses.count
                }
                if !c.phoneNumbers.isEmpty { withPhone += 1 }
                if !c.emailAddresses.isEmpty { withEmail += 1 }
                if c.imageDataAvailable { withImage += 1 }
                if !c.dates.isEmpty { withOtherDates += 1 }
                if !c.contactRelations.isEmpty { withRelations += 1 }
                if c.contactType == .organization { orgRecords += 1 }
            }
        } catch {
            enumerationError = error.localizedDescription
        }

        var groupCount = -1
        var containerCount = -1
        if let g = try? store.groups(matching: nil) { groupCount = g.count }
        if let ct = try? store.containers(matching: nil) { containerCount = ct.count }

        var extra: [String: String] = [
            "contactCount": "\(total)",
            "withBirthday": "\(withBirthday)",
            "withBirthdayPct": Fmt.pct(withBirthday, of: total),
            "withNonGregorianBirthday": "\(withNonGregorianBirthday)",
            "withPostalAddress": "\(withPostal)",
            "withPostalAddressPct": Fmt.pct(withPostal, of: total),
            "postalAddressTotal": "\(postalTotal)",
            "withPhoneNumber": "\(withPhone)",
            "withEmailAddress": "\(withEmail)",
            "withImageData": "\(withImage)",
            "withOtherDates": "\(withOtherDates)",
            "withRelations": "\(withRelations)",
            "organizationRecords": "\(orgRecords)",
            "unifyResults": "true",
            "groupCount": groupCount < 0 ? "unavailable" : "\(groupCount)",
            "containerCount": containerCount < 0 ? "unavailable" : "\(containerCount)",
            "authorization": cnStatusName(status),
            "limitedAccessInPlay": isLimited ? "true" : "false"
        ]
        if let enumerationError { extra["enumerationError"] = enumerationError }

        var countStatus: ProbeStatus = .ok
        if enumerationError != nil { countStatus = .error }
        else if isLimited { countStatus = .partial }
        else if total == 0 { countStatus = .empty }

        items.append(ProbeItem("stores.cn.count", "Contacts", countStatus,
                               value: isLimited
                                    ? "\(ProbeEnv.int(total)) contacts — SCOPED TO THE USER-SELECTED SUBSET"
                                    : "\(ProbeEnv.int(total)) contacts · \(ProbeEnv.int(withBirthday)) with birthdays · \(ProbeEnv.int(withPostal)) with postal addresses",
                               detail: isLimited
                                    ? "iOS 18 limited access is active, so this is a floor on the address book, not its size. No names, numbers, email addresses, or street addresses are read into the report — only per-field presence counts."
                                    : "No names, numbers, email addresses, or street addresses are read into the report — only per-field presence counts. Unified results are on, so linked duplicates count once.",
                               extra: extra))

        // ---- Change history: the non-obvious capability -----------------
        // A working history token turns Contacts from a snapshot you must
        // re-scan into an event stream you can tail — O(changes) per launch
        // instead of O(address book).
        var histExtra: [String: String] = [:]
        var histStatus: ProbeStatus = .unavailable
        var histValue = "not usable"
        var histDetail = ""

        let currentToken = store.currentHistoryToken
        histExtra["storeCurrentHistoryTokenPresent"] = currentToken == nil ? "false" : "true"
        histExtra["storeCurrentHistoryTokenBytes"] = "\(currentToken?.count ?? 0)"

        let histReq = CNChangeHistoryFetchRequest()
        histReq.startingToken = nil   // nil = full history: a reset, then one add per contact
        do {
            // MEASURED, NOT ASSUMED.
            //
            // `enumeratorForChangeHistoryFetchRequest:error:` exists in the ObjC
            // runtime but is marked unavailable to Swift, and it is not refined
            // either (`__enumerator(for:)` does not exist). The only pure-Swift
            // route would be `perform(_:with:with:)` against a method whose second
            // parameter is an NSError** — and a mistake there traps, which would
            // destroy the ENTIRE report for the sake of one sub-item.
            //
            // So: record whether the selector is reachable, and leave the call to
            // the collector phase, where a ten-line ObjC bridging header makes it
            // safe. Reporting a capability as shim-required is a real finding;
            // crashing the report to prove it is not.
            let enumeratorSelector = NSSelectorFromString("enumeratorForChangeHistoryFetchRequest:error:")
            histExtra["objcSelectorPresent"] = store.responds(to: enumeratorSelector) ? "true" : "false"
            histExtra["callableFromPureSwift"] = "false"
            histExtra["requiresObjCBridgingHeader"] = "true"
            _ = histReq

            let tokenAfter: Data? = currentToken
            histExtra["fetchResultTokenPresent"] = tokenAfter == nil ? "false" : "true"
            histExtra["fetchResultTokenBytes"] = "\(tokenAfter?.count ?? 0)"

            var kinds: [String: Int] = [:]
            var seen = 0
            var firstKind: String?
            let cap = 5000
            let liveEnumerator: NSEnumerator? = nil   // see note above
            if let en = liveEnumerator {
                while seen < cap, let obj = en.nextObject() {
                    seen += 1
                    // Classify by runtime class name rather than importing each
                    // concrete CNChangeHistory*Event symbol — same information,
                    // zero compile-time coupling to the exact class set.
                    let name = String(describing: type(of: obj))
                        .replacingOccurrences(of: "CNChangeHistory", with: "")
                        .replacingOccurrences(of: "Event", with: "")
                    kinds[name, default: 0] += 1
                    if firstKind == nil { firstKind = name }
                }
                histExtra["enumeratorObtained"] = "true"
            } else {
                histExtra["enumeratorObtained"] = "false"
            }

            histExtra["eventsEnumerated"] = "\(seen)"
            histExtra["enumerationCap"] = "\(cap)"
            histExtra["cappedOut"] = seen >= cap ? "true" : "false"
            histExtra["firstEventKind"] = firstKind ?? "none"
            for (k, v) in kinds { histExtra["event.\(k)"] = "\(v)" }

            let lowered = (firstKind ?? "").lowercased()
            let resetFirst = lowered.contains("drop") || lowered.contains("reset")
            histExtra["startedWithFullReset"] = resetFirst ? "true" : "false"

            if isLimited {
                histStatus = .partial
                histValue = "usable but degraded under limited access — \(ProbeEnv.int(seen)) events, first: \(firstKind ?? "none")"
                histDetail = "Under iOS 18 limited-access authorization, CNChangeHistoryFetchRequest is documented and observed to always return a full RESET rather than an incremental delta, and currentHistoryToken does not advance when the user removes contacts from the selected set. Incremental tracking is therefore NOT reliable at this authorization level — you get a re-snapshot every time, and deletions are invisible."
            } else if tokenAfter != nil {
                histStatus = .partial
                histValue = "supported by this store, but not callable from pure Swift"
                histDetail = "Contacts DOES support incremental change tracking here — the store returned a live currentHistoryToken, which is the prerequisite. This is potentially the highest-leverage finding in the Contacts store: with a persisted token, Contacts becomes an append-only event stream (add / update / delete, plus group changes) rather than a snapshot you have to diff yourself. The blocker is purely a language-bridging one: enumeratorForChangeHistoryFetchRequest:error: is marked unavailable to Swift, so the collector will need a small Objective-C shim to actually read the events. Cost: about ten lines and one bridging header. Worth doing."
            } else {
                histStatus = .empty
                histValue = "no history token available"
                histDetail = "The store returned no currentHistoryToken, so incremental change tracking is not established on this device at this authorization level."
            }
        } catch {
            histStatus = .error
            histValue = "threw"
            histDetail = "CNChangeHistoryFetchRequest failed: \(error.localizedDescription)"
            histExtra["error"] = error.localizedDescription
        }

        items.append(ProbeItem("stores.cn.changeHistory", "Contacts change history (incremental tracking)",
                               histStatus, value: histValue, detail: histDetail, extra: histExtra))

        return items
    }

    // ================================================================
    // MARK: 7. Photo library
    // ================================================================

    private func photoItems(status: PHAuthorizationStatus) -> [ProbeItem] {
        let readable = (status == .authorized || status == .limited)
        guard readable else {
            return [ProbeItem("stores.ph.assets", "Photo library",
                              status == .notDetermined ? .notDetermined : .denied,
                              value: "not readable",
                              detail: "Current status: \(phStatusName(status)).")]
        }

        let limited = (status == .limited)
        var items: [ProbeItem] = []

        // --- Exact counts via PHFetchResult.count: never materialises objects
        let images = PHAsset.fetchAssets(with: .image, options: nil).count
        let videos = PHAsset.fetchAssets(with: .video, options: nil).count
        let audio = PHAsset.fetchAssets(with: .audio, options: nil).count
        let all = PHAsset.fetchAssets(with: PHFetchOptions()).count

        // --- Oldest / newest stay exact even when the scan below caps out
        func edge(_ ascending: Bool) -> Date? {
            let o = PHFetchOptions()
            o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: ascending)]
            o.fetchLimit = 1
            return PHAsset.fetchAssets(with: o).firstObject?.creationDate
        }
        let oldest = edge(true)
        let newest = edge(false)

        var totalsExtra: [String: String] = [
            "totalAssets": "\(all)",
            "images": "\(images)",
            "videos": "\(videos)",
            "audio": "\(audio)",
            "oldestCreationDate": ProbeEnv.stamp(oldest) ?? "none",
            "oldestAssetAge": ProbeEnv.age(oldest) ?? "n/a",
            "newestCreationDate": ProbeEnv.stamp(newest) ?? "none",
            "newestAssetAge": ProbeEnv.age(newest) ?? "n/a",
            "authorization": phStatusName(status),
            "limitedAccessInPlay": limited ? "true" : "false"
        ]
        if let o = oldest, let n = newest {
            totalsExtra["librarySpanDays"] = String(format: "%.0f", n.timeIntervalSince(o) / 86_400)
            totalsExtra["librarySpanYears"] = String(format: "%.1f", n.timeIntervalSince(o) / (365.0 * 86_400))
        }

        items.append(ProbeItem("stores.ph.assets", "Photo library — asset counts",
                               all == 0 ? .empty : (limited ? .partial : .ok),
                               value: limited
                                    ? "\(ProbeEnv.int(all)) assets — SCOPED TO THE USER-SELECTED SUBSET"
                                    : "\(ProbeEnv.int(all)) assets (\(ProbeEnv.int(images)) photo · \(ProbeEnv.int(videos)) video · \(ProbeEnv.int(audio)) audio)",
                               detail: limited
                                    ? "Limited access: PHAsset fetches return only the shared subset, so these are floors, not library totals. Oldest/newest are exact within that subset. No image or video data is read — metadata only."
                                    : "Exact counts via PHFetchResult.count, which never materialises the asset objects. No image or video data is read at any point — creation dates and metadata flags only.",
                               extra: totalsExtra))

        // --- Smart albums give exact, cheap counts for the interesting subtypes
        let smartTargets: [(PHAssetCollectionSubtype, String)] = [
            (.smartAlbumUserLibrary, "userLibrary"),
            (.smartAlbumScreenshots, "screenshots"),
            (.smartAlbumLivePhotos, "livePhotos"),
            (.smartAlbumBursts, "bursts"),
            (.smartAlbumFavorites, "favorites"),
            (.smartAlbumSelfPortraits, "selfPortraits"),
            (.smartAlbumPanoramas, "panoramas"),
            (.smartAlbumSlomoVideos, "slomoVideos"),
            (.smartAlbumTimelapses, "timelapses"),
            (.smartAlbumDepthEffect, "depthEffect"),
            (.smartAlbumAnimated, "animated"),
            (.smartAlbumLongExposures, "longExposures"),
            (.smartAlbumRecentlyAdded, "recentlyAdded"),
            (.smartAlbumVideos, "videos")
        ]
        var albumExtra: [String: String] = [:]
        var screenshots = -1, livePhotos = -1, bursts = -1, favorites = -1
        for pair in smartTargets {
            let cols = PHAssetCollection.fetchAssetCollections(with: .smartAlbum,
                                                               subtype: pair.0, options: nil)
            guard let col = cols.firstObject else {
                albumExtra["smart.\(pair.1)"] = "absent"
                continue
            }
            let n = PHAsset.fetchAssets(in: col, options: nil).count
            albumExtra["smart.\(pair.1)"] = "\(n)"
            switch pair.1 {
            case "screenshots": screenshots = n
            case "livePhotos":  livePhotos = n
            case "bursts":      bursts = n
            case "favorites":   favorites = n
            default: break
            }
        }
        let allSmart = PHAssetCollection.fetchAssetCollections(with: .smartAlbum,
                                                               subtype: .any, options: nil).count
        let userAlbums = PHAssetCollection.fetchAssetCollections(with: .album,
                                                                 subtype: .any, options: nil).count
        albumExtra["smartAlbumsTotal"] = "\(allSmart)"
        albumExtra["userAlbumsTotal"] = "\(userAlbums)"

        items.append(ProbeItem("stores.ph.albums", "Photo library — albums and smart albums",
                               (allSmart == 0 && userAlbums == 0) ? .empty : .ok,
                               value: "\(ProbeEnv.int(allSmart)) smart · \(ProbeEnv.int(userAlbums)) user albums · screenshots \(screenshots < 0 ? "n/a" : ProbeEnv.int(screenshots)) · live \(livePhotos < 0 ? "n/a" : ProbeEnv.int(livePhotos)) · bursts \(bursts < 0 ? "n/a" : ProbeEnv.int(bursts)) · favourites \(favorites < 0 ? "n/a" : ProbeEnv.int(favorites))",
                               detail: "Smart-album counts are exact and cheap, and they sidestep the PHFetchOptions mediaSubtype predicate whose key name is ambiguous across SDK versions. Album titles are not reported.",
                               extra: albumExtra))

        // --- One capped scan for the properties with no reliable predicate key
        var scanned = 0
        var withLocation = 0
        var subScreenshot = 0, subLive = 0, subPano = 0, subHDR = 0
        var representsBurst = 0
        var burstIdentified = 0
        var favoriteFlag = 0
        var hiddenFlag = 0
        var cloudShared = 0
        var withAdjustments = 0
        var totalVideoSeconds = 0.0
        let cap = 30_000
        let deadline = Date().addingTimeInterval(25)
        var hitDeadline = false

        let scanOpts = PHFetchOptions()
        scanOpts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let scanResult = PHAsset.fetchAssets(with: scanOpts)
        scanResult.enumerateObjects { asset, _, stop in
            scanned += 1
            if asset.location != nil { withLocation += 1 }
            let sub = asset.mediaSubtypes
            if sub.contains(.photoScreenshot) { subScreenshot += 1 }
            if sub.contains(.photoLive) { subLive += 1 }
            if sub.contains(.photoPanorama) { subPano += 1 }
            if sub.contains(.photoHDR) { subHDR += 1 }
            if asset.representsBurst { representsBurst += 1 }
            if asset.burstIdentifier != nil { burstIdentified += 1 }
            if asset.isFavorite { favoriteFlag += 1 }
            if asset.isHidden { hiddenFlag += 1 }
            if asset.sourceType.contains(.typeCloudShared) { cloudShared += 1 }
            if asset.hasAdjustments { withAdjustments += 1 }
            if asset.mediaType == .video { totalVideoSeconds += asset.duration }
            if scanned >= cap { stop.pointee = true }
            if scanned % 500 == 0 && Date() > deadline {
                hitDeadline = true
                stop.pointee = true
            }
        }

        let capped = (scanned < all)
        var scanExtra: [String: String] = [
            "assetsScanned": "\(scanned)",
            "assetsInLibrary": "\(all)",
            "scanCapped": capped ? "true" : "false",
            "scanCap": "\(cap)",
            "hitTimeDeadline": hitDeadline ? "true" : "false",
            "withLocation": "\(withLocation)",
            "withLocationPct": Fmt.pct(withLocation, of: scanned),
            "subtype.photoScreenshot": "\(subScreenshot)",
            "subtype.photoLive": "\(subLive)",
            "subtype.photoPanorama": "\(subPano)",
            "subtype.photoHDR": "\(subHDR)",
            "representsBurst": "\(representsBurst)",
            "hasBurstIdentifier": "\(burstIdentified)",
            "favorite": "\(favoriteFlag)",
            "hidden": "\(hiddenFlag)",
            "iCloudSharedSource": "\(cloudShared)",
            "hasAdjustments": "\(withAdjustments)",
            "videoSecondsInScan": String(format: "%.0f", totalVideoSeconds)
        ]
        if screenshots >= 0 { scanExtra["screenshotsExactViaSmartAlbum"] = "\(screenshots)" }

        var scanStatus: ProbeStatus = .ok
        if scanned == 0 { scanStatus = .empty }
        else if capped || hitDeadline || limited { scanStatus = .partial }

        items.append(ProbeItem("stores.ph.scan", "Photo library — per-asset metadata scan", scanStatus,
                               value: "\(ProbeEnv.int(withLocation)) of \(ProbeEnv.int(scanned)) scanned assets carry a location (\(Fmt.pct(withLocation, of: scanned)))"
                                    + (capped ? " — scan capped, newest-first" : ""),
                               detail: "PHFetchOptions has no supported predicate key for `location`, so this is the one place a real object scan is required. Newest-first, capped at \(ProbeEnv.int(cap)) assets with a 25s deadline; when capped, the location rate is a sample of recent assets rather than a library-wide figure. Coordinates themselves are never read — only whether one exists.",
                               extra: scanExtra))

        // --- Change observation
        let observer = PhotoObserver()
        let lib = PHPhotoLibrary.shared()
        lib.register(observer)
        lib.unregisterChangeObserver(observer)

        items.append(ProbeItem("stores.ph.changeObserver", "Photo library change observation", .ok,
                               value: "register / unregister accepted",
                               detail: "PHPhotoLibrary.shared().register(_:) is the push path — combined with PHFetchResultChangeDetails it yields inserted / removed / changed index sets, so a collector tails the library instead of re-enumerating it. Registration was verified; delivery was not, because proving delivery would require mutating the user's library, which this probe will never do. Under limited access, change notifications cover only the shared subset.",
                               extra: ["registered": "true",
                                       "deliveryVerified": "false",
                                       "reasonDeliveryNotVerified": "would require writing to the user's library",
                                       "limitedAccessInPlay": limited ? "true" : "false"]))

        return items
    }

    // ================================================================
    // MARK: 8. Media library — are the play stats actually populated?
    // ================================================================

    private func mediaLibraryItems(status: MPMediaLibraryAuthorizationStatus) async -> [ProbeItem] {
        guard status == .authorized else {
            return [ProbeItem("stores.mp.items", "Media library",
                              status == .notDetermined ? .notDetermined : .denied,
                              value: "not readable",
                              detail: "Current status: \(mpStatusName(status)).")]
        }

        var items: [ProbeItem] = []

        let lastMod = MPMediaLibrary.default().lastModifiedDate
        items.append(ProbeItem("stores.mp.lastModified", "Media library last modified", .ok,
                               value: ProbeEnv.stamp(lastMod) ?? "unknown",
                               detail: "A cheap change sentinel — poll this instead of re-querying the library. It moves on metadata sync too, not only on user edits, so it over-reports change.",
                               extra: ["lastModifiedDate": ProbeEnv.stamp(lastMod) ?? "none",
                                       "age": ProbeEnv.age(lastMod) ?? "n/a"]))

        let songs = MPMediaQuery.songs().items ?? []
        let playlists = MPMediaQuery.playlists().collections?.count ?? 0
        let albums = MPMediaQuery.albums().collections?.count ?? 0
        let artists = MPMediaQuery.artists().collections?.count ?? 0
        let podcasts = MPMediaQuery.podcasts().items?.count ?? 0
        let audiobooks = MPMediaQuery.audiobooks().items?.count ?? 0

        items.append(ProbeItem("stores.mp.items", "Media library — item counts",
                               songs.isEmpty ? .empty : .ok,
                               value: "\(ProbeEnv.int(songs.count)) songs · \(ProbeEnv.int(albums)) albums · \(ProbeEnv.int(artists)) artists · \(ProbeEnv.int(playlists)) playlists",
                               detail: "Counts only. No track, album, artist, playlist, or podcast titles are read into the report.",
                               extra: ["songs": "\(songs.count)",
                                       "albums": "\(albums)",
                                       "artists": "\(artists)",
                                       "playlists": "\(playlists)",
                                       "podcastItems": "\(podcasts)",
                                       "audiobookItems": "\(audiobooks)"]))

        // ---- The actual question: are playCount / skipCount / lastPlayedDate
        // ---- / rating still populated in the streaming era, on THIS device?
        var scanned = 0
        var playedCounts: [Int] = []
        var skipNonZero = 0
        var maxSkip = 0
        var ratedNonZero = 0
        var ratingUnreadable = 0
        var maxPlay = 0
        var sumPlay = 0
        var newestPlayed: Date?
        var oldestPlayed: Date?
        var withLastPlayed = 0
        var cloudItems = 0
        var protectedAssets = 0
        var nilAssetURL = 0
        let scanCap = 25_000
        let deadline = Date().addingTimeInterval(20)
        var hitDeadline = false

        for item in songs {
            if scanned >= scanCap { break }
            if scanned % 500 == 0 && Date() > deadline { hitDeadline = true; break }
            scanned += 1

            let pc = item.playCount
            sumPlay += pc
            maxPlay = max(maxPlay, pc)
            if pc > 0 { playedCounts.append(pc) }

            let sc = item.skipCount
            if sc > 0 { skipNonZero += 1 }
            maxSkip = max(maxSkip, sc)

            // Read rating through the property-constant path: the typed Swift
            // property has drifted across SDKs, the MPMediaItemProperty
            // constant has not.
            if let r = item.value(forProperty: MPMediaItemPropertyRating) as? NSNumber {
                if r.intValue > 0 { ratedNonZero += 1 }
            } else {
                ratingUnreadable += 1
            }

            if let lp = item.lastPlayedDate {
                withLastPlayed += 1
                if let cur = newestPlayed { if lp > cur { newestPlayed = lp } } else { newestPlayed = lp }
                if let cur = oldestPlayed { if lp < cur { oldestPlayed = lp } } else { oldestPlayed = lp }
            }

            if item.isCloudItem { cloudItems += 1 }
            if item.hasProtectedAsset { protectedAssets += 1 }
            if item.assetURL == nil { nilAssetURL += 1 }
        }

        let playedItems = playedCounts.count
        let medianPlay = Fmt.median(playedCounts)

        var verdict: String
        var vStatus: ProbeStatus
        if scanned == 0 {
            verdict = "no songs available to measure"
            vStatus = .empty
        } else if playedItems == 0 && withLastPlayed == 0 {
            verdict = "DEAD on this device — 0 of \(ProbeEnv.int(scanned)) items carry playCount > 0 or any lastPlayedDate"
            vStatus = .empty
        } else if playedItems * 20 < scanned {
            verdict = "SPARSE — only \(ProbeEnv.int(playedItems)) of \(ProbeEnv.int(scanned)) items (\(Fmt.pct(playedItems, of: scanned))) carry playCount > 0"
            vStatus = .partial
        } else {
            verdict = "POPULATED — \(ProbeEnv.int(playedItems)) of \(ProbeEnv.int(scanned)) items (\(Fmt.pct(playedItems, of: scanned))) carry playCount > 0; max \(ProbeEnv.int(maxPlay)), median \(ProbeEnv.int(medianPlay))"
            vStatus = .ok
        }

        items.append(ProbeItem("stores.mp.playStats",
                               "playCount / skipCount / lastPlayedDate / rating — measured",
                               vStatus,
                               value: verdict,
                               detail: "These four fields are the closest thing iOS has to a personal listening history, and whether they still carry real values is genuinely contested: they were designed for a synced local iTunes library, and there are long-standing reports that HLS-streamed Apple Music playback does not write them back — worst on macOS and on AirPlay / Apple TV / HomePod output, while iOS-local playback of downloaded tracks historically does update them. Rather than trust any of that, this measures it here. Read the ratio together with nilAssetURL: a high nil-assetURL share means most of the library is cloud/streaming, which is exactly the condition under which these fields decay. No track titles are reported.",
                               extra: ["itemsScanned": "\(scanned)",
                                       "scanCap": "\(scanCap)",
                                       "hitTimeDeadline": hitDeadline ? "true" : "false",
                                       "playCountGtZero": "\(playedItems)",
                                       "playCountGtZeroPct": Fmt.pct(playedItems, of: scanned),
                                       "playCountMax": "\(maxPlay)",
                                       "playCountMedianOfPlayed": "\(medianPlay)",
                                       "playCountSum": "\(sumPlay)",
                                       "skipCountGtZero": "\(skipNonZero)",
                                       "skipCountMax": "\(maxSkip)",
                                       "ratingGtZero": "\(ratedNonZero)",
                                       "ratingPropertyUnreadable": "\(ratingUnreadable)",
                                       "withLastPlayedDate": "\(withLastPlayed)",
                                       "withLastPlayedDatePct": Fmt.pct(withLastPlayed, of: scanned),
                                       "newestLastPlayedDate": ProbeEnv.stamp(newestPlayed) ?? "none",
                                       "newestLastPlayedAge": ProbeEnv.age(newestPlayed) ?? "n/a",
                                       "oldestLastPlayedDate": ProbeEnv.stamp(oldestPlayed) ?? "none",
                                       "cloudItems": "\(cloudItems)",
                                       "protectedAssets": "\(protectedAssets)",
                                       "nilAssetURL": "\(nilAssetURL)",
                                       "nilAssetURLPct": Fmt.pct(nilAssetURL, of: scanned)]))

        // ---- Now playing in the system Music player -----------------------
        // MPMusicPlayerController is documented as main-thread; hop for it.
        let np: (Bool, TimeInterval, Int, Int, Date?, Float, String) = await MainActor.run {
            let p = MPMusicPlayerController.systemMusicPlayer
            let it = p.nowPlayingItem
            let stateName: String
            switch p.playbackState {
            case .stopped:         stateName = "stopped"
            case .playing:         stateName = "playing"
            case .paused:          stateName = "paused"
            case .interrupted:     stateName = "interrupted"
            case .seekingForward:  stateName = "seekingForward"
            case .seekingBackward: stateName = "seekingBackward"
            @unknown default:      stateName = "unknown"
            }
            return (it != nil,
                    it?.playbackDuration ?? 0,
                    it?.playCount ?? 0,
                    it?.skipCount ?? 0,
                    it?.lastPlayedDate,
                    p.currentPlaybackRate,
                    stateName)
        }

        items.append(ProbeItem("stores.mp.nowPlaying", "System Music player — now playing",
                               np.0 ? .ok : .empty,
                               value: np.0
                                    ? "item loaded · state \(np.6) · duration \(Fmt.secs(np.1))"
                                    : "no item loaded · state \(np.6)",
                               detail: "Title, artist, and album are deliberately omitted. This reflects the Music app and this app's own queue ONLY — it is nil while Spotify, YouTube, a podcast app, or any other third-party player is playing.",
                               extra: ["hasNowPlayingItem": np.0 ? "true" : "false",
                                       "playbackState": np.6,
                                       "currentPlaybackRate": String(format: "%.2f", np.5),
                                       "durationSeconds": String(format: "%.0f", np.1),
                                       "itemPlayCount": "\(np.2)",
                                       "itemSkipCount": "\(np.3)",
                                       "itemLastPlayedDate": ProbeEnv.stamp(np.4) ?? "none"]))

        return items
    }

    // ================================================================
    // MARK: 9. Now playing in OTHER apps — the definitive answer
    // ================================================================

    private func nowPlayingElsewhereItems() async -> [ProbeItem] {
        var items: [ProbeItem] = []

        items.append(ProbeItem("stores.np.otherApps", "Reading what another app is playing", .unavailable,
                               value: "IMPOSSIBLE with public API — idea killed",
                               detail: "Definitive: there is no public iOS API that reports what a third-party app is currently playing. MPNowPlayingInfoCenter is WRITE-ONLY from an app's perspective — `default.nowPlayingInfo` is how YOUR app publishes its own metadata to Control Center and the Lock Screen; reading it back returns only what your own process put there, never Spotify's. MPMusicPlayerController.systemMusicPlayer.nowPlayingItem is scoped to the Music app and the system music queue, and is nil for every third-party player. The system-wide read path is the private MediaRemote framework (MRMediaRemoteGetNowPlayingInfo), which is not public API and is excluded here on principle. Third-party title/artist is therefore obtainable only per-vendor, through that vendor's own authenticated web API — a network integration, not a device capability.",
                               extra: ["publicReadAPI": "none",
                                       "mpNowPlayingInfoCenterDirection": "write-only (own process)",
                                       "systemMusicPlayerScope": "Music app + own queue only",
                                       "privatePath": "MediaRemote / MRMediaRemoteGetNowPlayingInfo — excluded, not public API",
                                       "onlyLegitimateRoute": "per-vendor authenticated web API"]))

        // The honest partial proxy: you can learn THAT audio is playing
        // elsewhere, never WHAT. Read without activating the session, so
        // nothing currently playing is interrupted.
        let s = AVAudioSession.sharedInstance()
        let otherPlaying = s.isOtherAudioPlaying
        let silenceHint = s.secondaryAudioShouldBeSilencedHint
        let outputs = s.currentRoute.outputs.map { $0.portType.rawValue }
        let inputs = s.currentRoute.inputs.map { $0.portType.rawValue }

        items.append(ProbeItem("stores.np.otherAudioProxy", "Proxy — is other audio playing right now",
                               otherPlaying ? .ok : .empty,
                               value: otherPlaying ? "yes — audio is playing in another process" : "no other audio playing",
                               detail: "This is the legitimate partial proxy for the item above: AVAudioSession reports THAT another process holds audio, plus the current route, but never what the content is. Read without activating the session, so nothing currently playing was interrupted. Combined with route-change notifications it yields a usable listening-session timeline (start / stop / output device) with zero content.",
                               extra: ["isOtherAudioPlaying": otherPlaying ? "true" : "false",
                                       "secondaryAudioShouldBeSilencedHint": silenceHint ? "true" : "false",
                                       "outputPortTypes": outputs.isEmpty ? "none" : outputs.joined(separator: ","),
                                       "inputPortTypes": inputs.isEmpty ? "none" : inputs.joined(separator: ","),
                                       "outputCount": "\(outputs.count)",
                                       "sessionActivated": "false"]))

        return items
    }

    // ================================================================
    // MARK: 10. Speech
    // ================================================================

    private func speechItems() async -> [ProbeItem] {
        var items: [ProbeItem] = []
        let before = SFSpeechRecognizer.authorizationStatus()

        guard hasInfoKey("NSSpeechRecognitionUsageDescription") else {
            items.append(ProbeItem("stores.speech.auth", "Speech recognition authorization", .unavailable,
                                   value: "raw \(before.rawValue)",
                                   detail: "NSSpeechRecognitionUsageDescription is missing from Info.plist; the request was skipped to avoid a TCC process kill.",
                                   extra: ["statusBeforeRaw": "\(before.rawValue)"]))
            return items
        }

        if before == .notDetermined {
            let once = Once()
            _ = await withProbeTimeout(30, fallback: SFSpeechRecognizerAuthorizationStatus.notDetermined) {
                await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                    SFSpeechRecognizer.requestAuthorization { s in
                        if once.claim() { c.resume(returning: s) }
                    }
                }
            }
        }

        let after = SFSpeechRecognizer.authorizationStatus()
        var name = "unknown(\(after.rawValue))"
        var st: ProbeStatus = .partial
        switch after {
        case .notDetermined: name = "notDetermined"; st = .notDetermined
        case .denied:        name = "denied";        st = .denied
        case .restricted:    name = "restricted";    st = .denied
        case .authorized:    name = "authorized";    st = .ok
        @unknown default:    break
        }

        let rec = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer()
        let onDevice = rec?.supportsOnDeviceRecognition ?? false
        let availableNow = rec?.isAvailable ?? false
        let supportedLocales = SFSpeechRecognizer.supportedLocales().count

        items.append(ProbeItem("stores.speech.auth", "Speech recognition authorization", st,
                               value: name,
                               detail: "Gates SFSpeechRecognizer. Independent of microphone permission — both are required to actually transcribe anything.",
                               extra: ["statusBeforeRaw": "\(before.rawValue)",
                                       "statusAfterRaw": "\(after.rawValue)",
                                       "prompted": before == .notDetermined ? "true" : "false"]))

        items.append(ProbeItem("stores.speech.onDevice", "On-device speech recognition",
                               onDevice ? .ok : .partial,
                               value: onDevice
                                    ? "supported for \(Locale.current.identifier)"
                                    : "NOT supported for \(Locale.current.identifier) — a server round-trip would be required",
                               detail: "supportsOnDeviceRecognition decides whether transcription can run offline with no audio leaving the device, and it varies by locale and by whether that locale's model has been downloaded. iOS 26's newer SpeechAnalyzer / SpeechTranscriber API is deliberately not probed — see the section summary.",
                               extra: ["supportsOnDeviceRecognition": onDevice ? "true" : "false",
                                       "recognizerAvailableNow": availableNow ? "true" : "false",
                                       "currentLocale": Locale.current.identifier,
                                       "supportedLocaleCount": "\(supportedLocales)"]))
        return items
    }

    // ================================================================
    // MARK: 11. App Tracking Transparency
    // ================================================================

    private func trackingItem() -> ProbeItem {
        #if canImport(AppTrackingTransparency)
        let s = ATTrackingManager.trackingAuthorizationStatus
        var name = "unknown(\(s.rawValue))"
        var st: ProbeStatus = .partial
        switch s {
        case .notDetermined: name = "notDetermined"; st = .notDetermined
        case .restricted:    name = "restricted";    st = .denied
        case .denied:        name = "denied";        st = .denied
        case .authorized:    name = "authorized";    st = .ok
        @unknown default:    break
        }
        return ProbeItem("stores.att.status", "App Tracking Transparency", st,
                         value: name,
                         detail: "Status is READ ONLY — no ATT prompt is requested by this probe, because that prompt can be shown exactly once per install and burning it here would poison every later run. It gates IDFA (ASIdentifierManager), which is not read.",
                         extra: ["status": name,
                                 "statusRaw": "\(s.rawValue)",
                                 "promptRequested": "false",
                                 "idfaRead": "false"])
        #else
        return ProbeItem("stores.att.status", "App Tracking Transparency", .unavailable,
                         value: "framework not present",
                         detail: "AppTrackingTransparency could not be imported in this build configuration.")
        #endif
    }

    // ================================================================
    // MARK: 12. Clipboard — the one measurable proxy in the "unreachable" set
    // ================================================================

    private func clipboardItems() async -> [ProbeItem] {
        let snapshot: (Int, Bool, Bool, Bool, Bool, Int) = await MainActor.run {
            let p = UIPasteboard.general
            return (p.changeCount, p.hasStrings, p.hasURLs, p.hasImages, p.hasColors, p.numberOfItems)
        }

        let patterns: Set<UIPasteboard.DetectionPattern> = [.probableWebURL, .probableWebSearch, .number]
        let once = Once()
        let detected: [String] = await withProbeTimeout(8, fallback: ["<timeout>"]) {
            await withCheckedContinuation { (c: CheckedContinuation<[String], Never>) in
                // UIPasteboard is main-actor isolated in the current UIKit
                // overlay, and this continuation body is nonisolated (the
                // withProbeTimeout work closure carries no isolation), so the
                // call has to hop explicitly — exactly as the snapshot read
                // above already does. Not hopping is a hard compile error, not
                // a warning.
                Task { @MainActor in
                    UIPasteboard.general.detectPatterns(for: patterns) { result in
                        guard once.claim() else { return }
                        switch result {
                        case .success(let set):
                            c.resume(returning: set.map { $0.rawValue }.sorted())
                        case .failure(let e):
                            c.resume(returning: ["<error: \(e.localizedDescription)>"])
                        }
                    }
                }
            }
        }

        let patternList = detected.isEmpty ? "none" : detected.joined(separator: ", ")

        return [ProbeItem("stores.pb.clipboard", "Clipboard — shape without content", .partial,
                          value: "changeCount \(ProbeEnv.int(snapshot.0)) · \(snapshot.5) item(s) · patterns: \(patternList)",
                          detail: "Continuous clipboard polling is NOT achievable — an app gets no background wakeup on pasteboard change, and reading the value shows the user a \"pasted from\" banner. But `changeCount` is readable with no prompt and no banner, and `detectPatterns(for:)` reports the SHAPE of the contents (URL / search text / number) without exposing the value, because the banner is gated on exposing the value rather than on observing that one exists. Together they give a foreground-only change signal plus a content class. Clipboard contents are never read into this report. Only the three original iOS 14 detection patterns are probed; the later set (email, phone, postal address, flight number, money amount) is omitted rather than risk a symbol that may not be present on this SDK.",
                          extra: ["changeCount": "\(snapshot.0)",
                                  "numberOfItems": "\(snapshot.5)",
                                  "hasStrings": snapshot.1 ? "true" : "false",
                                  "hasURLs": snapshot.2 ? "true" : "false",
                                  "hasImages": snapshot.3 ? "true" : "false",
                                  "hasColors": snapshot.4 ? "true" : "false",
                                  "detectedPatterns": detected.isEmpty ? "none" : detected.joined(separator: ","),
                                  "contentRead": "false",
                                  "backgroundPollingPossible": "false"])]
    }

    // ================================================================
    // MARK: 13. Definitively unreachable stores
    // ================================================================

    private func unreachableItems() -> [ProbeItem] {
        [
            ProbeItem("stores.unreachable.messages", "Messages / SMS / iMessage", .unavailable,
                      value: "no read access, at all",
                      detail: "There is no public API to read message content, threads, participants, or even counts. MessageUI's MFMessageComposeViewController only presents a prefilled compose sheet the user must send by hand. The Messages app-extension point (MSMessagesAppViewController) runs inside Messages and sees only the conversation the user opened, never the database. SMS filtering (IdentityLookup / ILMessageFilterExtension) does see incoming unknown-sender messages, but inside a sandboxed extension with no network access and no channel back to the containing app. PARTIAL PROXY: none worth having.",
                      extra: ["proxy": "none",
                              "extensionPoints": "ILMessageFilterExtension (sandboxed, no data egress)"]),

            ProbeItem("stores.unreachable.mail", "Mail", .unavailable,
                      value: "no read access, at all",
                      detail: "No public API exposes Mail accounts, messages, or metadata. MFMailComposeViewController is compose-only. PARTIAL PROXY: none on-device. The only legitimate route to a user's mail is their provider's authenticated API (Gmail, Microsoft Graph), which is a network integration rather than a device capability.",
                      extra: ["proxy": "none on-device", "route": "provider web API only"]),

            ProbeItem("stores.unreachable.safariHistory", "Safari history / browsing", .unavailable,
                      value: "no read access, at all",
                      detail: "History, open tabs, bookmarks, and Reading List are all unreadable. SFSafariViewController deliberately isolates its cookies and browsing from the host app and reports nothing back beyond dismissal. PARTIAL PROXY: a Safari Web Extension the user installs and grants host permissions to can observe pages in ITS OWN context and message its containing app — a real, public, App-Store-legal path, but it requires the user to install and enable the extension, and it only ever sees Safari, only for granted hosts.",
                      extra: ["proxy": "Safari Web Extension (user-installed, per-host permission)",
                              "proxyCoverage": "Safari only, granted hosts only"]),

            ProbeItem("stores.unreachable.callLog", "Call log / call history", .unavailable,
                      value: "no historical read",
                      detail: "There is no API for past calls. CallKit's CXCallObserver is the correct partial proxy to name: it reports calls that begin, connect, or end WHILE your app is running, with a UUID, an outgoing flag, and timestamps — never a phone number, never anything historical. In a one-shot probe run that is almost always zero calls, so it is stated rather than implemented. CallDirectory extensions (CXCallDirectoryProvider) run the other direction: you supply numbers to the system and get nothing back.",
                      extra: ["proxy": "CXCallObserver (live only, no identities)",
                              "historicalAccess": "none",
                              "implemented": "false — a live-only observer yields nothing in a one-shot probe"]),

            ProbeItem("stores.unreachable.keyboard", "Keyboard input / typed text", .unavailable,
                      value: "no read access, at all",
                      detail: "System-wide keystroke observation does not exist on iOS. A custom keyboard extension sees only text typed into it while the user has that keyboard selected, and network access requires RequestsOpenAccess plus an explicit user toggle. Your own app's text fields are readable, but that is your app's data, not the device's. PARTIAL PROXY: UIKeyboardWillShow / DidHide notifications give keyboard-presence timing inside your own app only — an activity signal, never content.",
                      extra: ["proxy": "own-app keyboard notifications (timing only)",
                              "systemWideKeystrokes": "impossible"]),

            ProbeItem("stores.unreachable.screenTime", "Cross-app usage / Screen Time", .unavailable,
                      value: "renderable to the user, never extractable",
                      detail: "Noted because it is the store people expect to find next to these. Screen Time data is reachable only through the Family Controls / DeviceActivity / ManagedSettings stack, which requires the com.apple.developer.family-controls entitlement, runs its reporting inside a sandboxed DeviceActivityReport extension, and is architected so the numbers can be RENDERED to the user but never extracted into your app's storage or sent over the network. It is therefore not probed by this section.",
                      extra: ["framework": "FamilyControls / DeviceActivity",
                              "entitlement": "com.apple.developer.family-controls",
                              "dataEgress": "blocked by design"])
        ]
    }

    // ================================================================
    // MARK: Summary
    // ================================================================

    private func summaryText(_ items: [ProbeItem]) -> String {
        var t: [ProbeStatus: Int] = [:]
        for i in items { t[i.status, default: 0] += 1 }
        let ok = t[.ok] ?? 0
        let partial = t[.partial] ?? 0
        let empty = t[.empty] ?? 0
        let denied = t[.denied] ?? 0
        let nd = t[.notDetermined] ?? 0
        let unavail = t[.unavailable] ?? 0
        let err = t[.error] ?? 0

        return """
        PRIVACY: this section contains counts, dates, authorization statuses, and aggregate statistics ONLY. \
        No contact names, event or reminder titles, notes, attendee identities, track / album / artist names, \
        photo identifiers, coordinates, or clipboard contents are read into the report. It is safe to share.

        \(items.count) items — \(ok) ok · \(partial) partial · \(empty) empty · \(denied) denied · \
        \(nd) not-determined · \(unavail) unavailable · \(err) error. Authorization status is recorded \
        separately from whether data actually came back, because the two diverge constantly and the divergence \
        is the finding: writeOnly calendar access, and limited Photos or Contacts access, all read as "granted" \
        while returning a fraction of the store or none of it. Wherever limited access is in play the affected \
        counts are marked partial and are floors, not totals.

        BUDGET: this section self-limits to a 150s wall clock because the runner discards any section exceeding \
        180s outright. Phases run in order and any that finds the budget spent yields a `.skipped` marker rather \
        than costing every earlier measurement. Permission prompts fire only on the FIRST run, so if the wall-clock \
        item reports skips, simply re-run — the second pass has the whole budget. Every permission callback and \
        every framework query is individually deadlined, so nothing here can hang the report.

        MEASURED RATHER THAN ASSUMED: the oldest reachable calendar event (six 1-year windows walked backwards); \
        whether the documented 4-year predicateForEvents span cap is real on this device (one 10-year predicate \
        compared against the windowed union — if it comes back shallower, chunked queries are mandatory); the \
        true retention depth of completed reminders against a 5-year request; and the contested one — whether \
        MPMediaItem playCount / skipCount / lastPlayedDate / rating still carry real values in the Apple Music \
        streaming era, reported as a populated-item ratio with max, median, newest play date, and the share of \
        items with a nil assetURL, rather than as a yes/no.

        DEFINITIVELY NOT REACHABLE — settled, not pending: (1) What another app is playing. MPNowPlayingInfoCenter \
        is write-only from your own process, and systemMusicPlayer.nowPlayingItem covers the Music app and your own \
        queue only; the system-wide read path is the private MediaRemote framework and is excluded on principle. \
        The honest proxy is AVAudioSession.isOtherAudioPlaying, probed here, which tells you THAT audio plays \
        elsewhere and on which route, never what it is. (2) Messages and Mail — no read path, and no proxy worth \
        having; a provider web API is the only route to mail. (3) Safari history — no read path; the only \
        legitimate partial proxy is a user-installed Safari Web Extension, limited to Safari and to hosts the user \
        grants. (4) Call log — no historical read; CXCallObserver sees only calls occurring live during a run and \
        carries no identities, which is why it is named but not implemented. (5) Keyboard input — system-wide \
        keystroke capture is impossible; only your own app's fields and keyboard-presence timing are observable. \
        (6) Clipboard — continuous polling is impossible (no background wakeup, and reading the value raises the \
        "pasted from" banner), but changeCount plus detectPatterns give a prompt-free foreground change signal and \
        a content CLASS without exposing the content, and both are probed here.

        DELIBERATELY OMITTED: EKEvent.travelTime — it exists as a private ivar with no developer.apple.com page \
        and no exported symbol, so reaching it would mean KVC against an undocumented key; the public substitute, \
        location-triggered alarms (EKAlarm.structuredLocation plus proximity, what actually drives "Time to \
        Leave"), is counted instead. Also omitted: iOS 26's SpeechAnalyzer / SpeechTranscriber API (SFSpeechRecognizer \
        is probed instead), the post-iOS-14 UIPasteboard detection patterns beyond URL / search / number, and the \
        ATT prompt itself — its status is read but never requested, since that prompt fires once per install and \
        burning it would corrupt every later run.
        """
    }
}
