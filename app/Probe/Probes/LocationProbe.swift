import Foundation
import CoreLocation

// =============================================================================
// LocationProbe — CoreLocation ground truth for one specific iPhone.
//
// Location is the spine of a life log. The single most important architectural
// fact this file establishes is WHICH CoreLocation services relaunch a
// terminated app and which silently stop, because that determines whether a
// background collector can survive at all.
//
// Every helper type/function in this file is prefixed `LocationProbe` on
// purpose: all eleven probe files compile into ONE module, so an unprefixed
// `Once` / `Fmt` / `Session` would collide with another agent's file.
//
// Facts below are quoted from Apple's own documentation (verified 2026-07-24
// via developer.apple.com/tutorials/data/documentation/corelocation/*.json),
// not from memory:
//   • startMonitoring(for:)        — "An app can register up to 20 regions at a time."
//   • allowsBackgroundLocationUpdates — "Setting the value to true but omitting
//     the UIBackgroundModes key and location value in your app's Info.plist
//     file is a fatal error that terminates the app."
//   • startMonitoringVisits()      — "If your app is terminated while this
//     service is active, the system relaunches your app when new visit events
//     are ready to be delivered."
//   • startMonitoringSignificantLocationChanges() — "If you start this service
//     and your app is subsequently terminated, the system automatically
//     relaunches the app into the background if a new event arrives."
// =============================================================================

// MARK: - Exactly-once resume guard

/// Guarantees a `CheckedContinuation` is resumed exactly once even when the
/// delegate callback that resumes it can fire repeatedly (CoreLocation
/// delegates absolutely do).
private final class LocationProbeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    /// Returns true to exactly one caller, ever.
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

// MARK: - Timeout that actually returns

/// `withProbeTimeout` in ProbeCore uses `withTaskGroup`, which implicitly
/// awaits ALL child tasks before returning — so a child that ignores
/// cancellation (CoreLocation's async sequences can) wedges it forever.
/// This variant resumes an outer continuation on whichever arm wins, so it
/// returns on deadline no matter what the worker does.
private enum LocationProbeRace {
    static func run<T>(_ seconds: Double,
                       fallback: T,
                       _ work: @escaping () async -> T) async -> T {
        let once = LocationProbeOnce()
        return await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
            let worker = Task {
                let v = await work()
                if once.claim() { cont.resume(returning: v) }
            }
            Task {
                let ns = UInt64(max(0.1, seconds) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
                if once.claim() {
                    worker.cancel()
                    cont.resume(returning: fallback)
                }
            }
        }
    }
}

// MARK: - Formatting / redaction

private enum LocationProbeFmt {

    /// Coordinates are DELIBERATELY truncated to 3 decimal places before they
    /// ever reach a report string. 3 dp ≈ 110 m of latitude and ≈ 85 m of
    /// longitude at 40°N — enough to confirm a real fix landed and to sanity
    /// check the city, and not enough to identify a residence. This is
    /// truncation, not anonymisation: a 110 m box still narrows a city block.
    /// Never interpolate a `CLLocation` directly — its `description` carries
    /// full precision.
    static func coord(_ c: CLLocationCoordinate2D) -> String {
        String(format: "%.3f, %.3f", c.latitude, c.longitude)
    }

    static func m(_ v: CLLocationDistance) -> String {
        v < 0 ? "invalid (\(ProbeEnv.num(v)))" : "\(ProbeEnv.num(v)) m"
    }

    static func auth(_ s: CLAuthorizationStatus) -> String {
        switch s {
        case .notDetermined:       return "notDetermined"
        case .restricted:          return "restricted"
        case .denied:              return "denied"
        case .authorizedAlways:    return "authorizedAlways"
        case .authorizedWhenInUse: return "authorizedWhenInUse"
        @unknown default:          return "unknown(\(s.rawValue))"
        }
    }

    static func accuracy(_ a: CLAccuracyAuthorization) -> String {
        switch a {
        case .fullAccuracy:    return "fullAccuracy"
        case .reducedAccuracy: return "reducedAccuracy"
        @unknown default:      return "unknown(\(a.rawValue))"
        }
    }

    /// Maps a raw `CLAuthorizationStatus` onto the report's status vocabulary.
    static func status(for s: CLAuthorizationStatus) -> ProbeStatus {
        switch s {
        case .authorizedAlways:    return .ok
        case .authorizedWhenInUse: return .partial
        case .denied, .restricted: return .denied
        case .notDetermined:       return .notDetermined
        @unknown default:          return .error
        }
    }

    static func clError(_ e: Error) -> String {
        if let c = e as? CLError {
            return "CLError.\(clErrorName(c.code)) (\(c.code.rawValue)) — \(c.localizedDescription)"
        }
        let ns = e as NSError
        return "\(ns.domain) \(ns.code) — \(ns.localizedDescription)"
    }

    static func clErrorName(_ c: CLError.Code) -> String {
        switch c {
        case .locationUnknown:              return "locationUnknown"
        case .denied:                       return "denied"
        case .network:                      return "network"
        case .headingFailure:               return "headingFailure"
        case .regionMonitoringDenied:       return "regionMonitoringDenied"
        case .regionMonitoringFailure:      return "regionMonitoringFailure"
        case .regionMonitoringSetupDelayed: return "regionMonitoringSetupDelayed"
        case .regionMonitoringResponseDelayed: return "regionMonitoringResponseDelayed"
        case .geocodeFoundNoResult:         return "geocodeFoundNoResult"
        case .geocodeFoundPartialResult:    return "geocodeFoundPartialResult"
        case .geocodeCanceled:              return "geocodeCanceled"
        case .deferredFailed:               return "deferredFailed"
        case .deferredNotUpdatingLocation:  return "deferredNotUpdatingLocation"
        case .deferredAccuracyTooLow:       return "deferredAccuracyTooLow"
        case .deferredDistanceFiltered:     return "deferredDistanceFiltered"
        case .deferredCanceled:             return "deferredCanceled"
        case .rangingUnavailable:           return "rangingUnavailable"
        case .rangingFailure:               return "rangingFailure"
        case .promptDeclined:               return "promptDeclined"
        default:                            return "code\(c.rawValue)"
        }
    }
}

// MARK: - Crash guard for APIs that can trap

/// A trap cannot be caught, so the race helper above cannot protect against
/// one. `CLMonitor`'s async initialiser has an open, unresolved crash report
/// (developer.apple.com/forums/thread/802143 — Apple's position is that the
/// API is production-ready and the crash is caller-side). Rather than gamble
/// the whole report on that, we record an attempt in UserDefaults BEFORE the
/// call and a completion after. If attempts outrun completions by 2, a past
/// run died inside the call and we skip it permanently — turning an
/// unrecoverable trap into a one-time cost plus a permanent, reportable finding.
private enum LocationProbeCrashGuard {
    private static let p = "LocationProbe.guard."

    /// - Returns: (shouldAttempt, unfinishedAttemptsSoFar)
    static func shouldAttempt(_ name: String) -> (Bool, Int) {
        let d = UserDefaults.standard
        let a = d.integer(forKey: p + name + ".attempts")
        let c = d.integer(forKey: p + name + ".completions")
        let unfinished = max(0, a - c)
        if unfinished >= 2 { return (false, unfinished) }
        d.set(a + 1, forKey: p + name + ".attempts")
        return (true, unfinished)
    }

    static func complete(_ name: String) {
        let d = UserDefaults.standard
        d.set(d.integer(forKey: p + name + ".completions") + 1,
              forKey: p + name + ".completions")
    }
}

// MARK: - Outcomes

private enum LocationProbeFixOutcome {
    case got(CLLocation)
    case failed(Error)
    case timedOut
}

/// Result of iterating `CLLocationUpdate.liveUpdates()` for a bounded window.
private struct LocationProbeLiveResult {
    var arrived = false
    var coord: CLLocationCoordinate2D?
    var accuracy: CLLocationAccuracy = -1
    var stationary = false
    var timestamp: Date?
    var flags: [String: String] = [:]
    var error: String?
}

/// Result of exercising the `CLMonitor` actor.
private struct LocationProbeMonitorResult {
    var created = false
    var identifiers: [String] = []
    var recordState: String?
    var removed = false
    var note: String?
}

/// Result of one `CLGeocoder` reverse-geocode, already stripped of street detail.
private struct LocationProbeGeoResult {
    var locality: String?
    var subAdmin: String?
    var admin: String?
    var country: String?
    var isoCountry: String?
    var timeZone: String?
    var inland: String?
    var ocean: String?
    var error: String?
    var rateLimited = false
    var timedOut = false
}

// MARK: - The manager + delegate

/// Owns the one `CLLocationManager` used by this probe.
///
/// CRITICAL: `CLLocationManager` delivers delegate callbacks on the run loop of
/// the thread it was created on. `run()` is nonisolated, so it executes on the
/// cooperative pool, which has NO run loop — a manager created there never
/// calls back and every wait would silently time out, producing a section that
/// looks exactly like a denied permission. Everything that touches the manager
/// therefore hops to the main thread.
private final class LocationProbeSession: NSObject, CLLocationManagerDelegate, @unchecked Sendable {

    private let manager: CLLocationManager
    private let lock = NSLock()

    // Waiters (each cleared under the lock before being invoked).
    private var authBaseline: CLAuthorizationStatus?
    private var authWaiter: ((CLAuthorizationStatus) -> Void)?
    /// Bumped on every arm. A timeout task only disarms the waiter it armed —
    /// without this, the 45 s When-In-Use deadline could fire after the 20 s
    /// Always wait had already armed itself and silently disarm it.
    private var authGeneration = 0
    private var fixWaiter: ((LocationProbeFixOutcome) -> Void)?

    // Passively accumulated state.
    private var latestHeading: CLHeading?
    private var visits: [CLVisit] = []
    private var regionFailures: [String] = []
    private var locationFailures: [String] = []
    private var authCallbackCount = 0
    private var regionEvents: [String] = []

    private override init() {
        manager = CLLocationManager()
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
    }

    /// Builds the session on the main thread. Never fails.
    static func create() async -> LocationProbeSession {
        await withCheckedContinuation { (c: CheckedContinuation<LocationProbeSession, Never>) in
            if Thread.isMainThread {
                c.resume(returning: LocationProbeSession())
            } else {
                DispatchQueue.main.async { c.resume(returning: LocationProbeSession()) }
            }
        }
    }

    /// Runs `body` against the manager on the main thread and returns its value.
    /// Deliberately continuation-based rather than `MainActor.run`, because
    /// `MainActor.run` constrains its return type to `Sendable` and several
    /// CoreLocation value types are not.
    func onMain<T>(_ body: @escaping (CLLocationManager) -> T) async -> T {
        await withCheckedContinuation { (c: CheckedContinuation<T, Never>) in
            if Thread.isMainThread {
                c.resume(returning: body(self.manager))
            } else {
                DispatchQueue.main.async { c.resume(returning: body(self.manager)) }
            }
        }
    }

    // MARK: Waits

    /// Waits for `authorizationStatus` to become something other than
    /// `baseline`. The delegate fires an immediate callback carrying the
    /// CURRENT status the moment a delegate is assigned, so the waiter ignores
    /// any callback that still reports the baseline and stays armed.
    ///
    /// Resume-exactly-once is enforced by `LocationProbeOnce`: the delegate arm
    /// and the timeout arm both have to claim it, and only one can.
    func awaitAuthChange(from baseline: CLAuthorizationStatus,
                         timeout: Double) async -> CLAuthorizationStatus? {
        let once = LocationProbeOnce()
        return await withCheckedContinuation { (cont: CheckedContinuation<CLAuthorizationStatus?, Never>) in
            self.lock.lock()
            self.authGeneration += 1
            let generation = self.authGeneration
            self.authBaseline = baseline
            self.authWaiter = { s in if once.claim() { cont.resume(returning: s) } }
            self.lock.unlock()

            // ARM-THEN-RECHECK. The caller issues request*Authorization() on the
            // main thread and only then awaits this function, which resumes on
            // the cooperative pool — so CoreLocation's delegate callback can win
            // the race and fire BEFORE the waiter is armed. That is not an edge
            // case: the PROVISIONAL Always upgrade has no sheet and no human, so
            // its callback is exactly the fastest one. Missing it would park here
            // for the full timeout and make the elapsed-time test report a
            // provisional grant as a second user-facing prompt — inverting the
            // single finding this item exists to establish.
            DispatchQueue.main.async {
                let now = self.manager.authorizationStatus
                guard now != baseline else { return }
                self.lock.lock()
                var fire: ((CLAuthorizationStatus) -> Void)?
                if self.authGeneration == generation, self.authWaiter != nil {
                    fire = self.authWaiter
                    self.authWaiter = nil
                    self.authBaseline = nil
                }
                self.lock.unlock()
                fire?(now)
            }

            Task {
                let ns = UInt64(max(0.1, timeout) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
                self.lock.lock()
                if self.authGeneration == generation {
                    self.authWaiter = nil
                    self.authBaseline = nil
                }
                self.lock.unlock()
                if once.claim() { cont.resume(returning: nil) }
            }
        }
    }

    /// One-shot fix via `requestLocation()`. Resolves on the first of:
    /// didUpdateLocations, didFailWithError, or the deadline.
    func requestOneFix(timeout: Double) async -> LocationProbeFixOutcome {
        let once = LocationProbeOnce()
        return await withCheckedContinuation { (cont: CheckedContinuation<LocationProbeFixOutcome, Never>) in
            self.lock.lock()
            self.fixWaiter = { o in if once.claim() { cont.resume(returning: o) } }
            self.lock.unlock()

            DispatchQueue.main.async { self.manager.requestLocation() }

            Task {
                let ns = UInt64(max(0.1, timeout) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
                self.lock.lock()
                self.fixWaiter = nil
                self.lock.unlock()
                if once.claim() { cont.resume(returning: .timedOut) }
            }
        }
    }

    // MARK: Passive readers

    func heading() -> CLHeading? { lock.lock(); defer { lock.unlock() }; return latestHeading }
    func visitSamples() -> [CLVisit] { lock.lock(); defer { lock.unlock() }; return visits }
    func regionFailureList() -> [String] { lock.lock(); defer { lock.unlock() }; return regionFailures }
    func locationFailureList() -> [String] { lock.lock(); defer { lock.unlock() }; return locationFailures }
    func regionEventList() -> [String] { lock.lock(); defer { lock.unlock() }; return regionEvents }
    func authCallbacks() -> Int { lock.lock(); defer { lock.unlock() }; return authCallbackCount }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        let status = m.authorizationStatus
        lock.lock()
        authCallbackCount += 1
        var fire: ((CLAuthorizationStatus) -> Void)?
        if let base = authBaseline, authWaiter != nil, status != base {
            fire = authWaiter
            authWaiter = nil
            authBaseline = nil
        }
        lock.unlock()
        fire?(status)
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        lock.lock()
        let w = fixWaiter
        fixWaiter = nil
        lock.unlock()
        w?(.got(last))
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        lock.lock()
        locationFailures.append(LocationProbeFmt.clError(error))
        let w = fixWaiter
        fixWaiter = nil
        lock.unlock()
        w?(.failed(error))
    }

    func locationManager(_ m: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        lock.lock(); latestHeading = newHeading; lock.unlock()
    }

    func locationManagerShouldDisplayHeadingCalibration(_ m: CLLocationManager) -> Bool {
        // Never take over the screen with the calibration HUD during a probe run.
        false
    }

    func locationManager(_ m: CLLocationManager, didVisit visit: CLVisit) {
        lock.lock(); visits.append(visit); lock.unlock()
    }

    func locationManager(_ m: CLLocationManager,
                         monitoringDidFailFor region: CLRegion?,
                         withError error: Error) {
        let name = region?.identifier ?? "<nil region>"
        let reason = LocationProbeFmt.clError(error)
        lock.lock()
        regionFailures.append("\(name): \(reason)")
        lock.unlock()
    }

    func locationManager(_ m: CLLocationManager, didStartMonitoringFor region: CLRegion) {
        lock.lock(); regionEvents.append("didStartMonitoring: \(region.identifier)"); lock.unlock()
    }

    func locationManager(_ m: CLLocationManager, didEnterRegion region: CLRegion) {
        lock.lock(); regionEvents.append("didEnter: \(region.identifier)"); lock.unlock()
    }

    func locationManager(_ m: CLLocationManager, didExitRegion region: CLRegion) {
        lock.lock(); regionEvents.append("didExit: \(region.identifier)"); lock.unlock()
    }
}

// MARK: - Probe

struct LocationProbe: TelemetryProbe {
    let key = "location"
    let title = "CoreLocation"

    func run() async -> ProbeSection {
        var items: [ProbeItem] = []

        // The whole section must finish well inside ProbeRunner's 180 s budget,
        // because on timeout the runner DISCARDS everything collected here and
        // replaces it with a single .error item. There is no partial credit, so
        // every wait below is individually short.
        let session = await LocationProbeSession.create()

        // ---------------------------------------------------------------
        // 1. Authorization
        // ---------------------------------------------------------------
        let startStatus = await session.onMain { $0.authorizationStatus }
        let startAccuracy = await session.onMain { $0.accuracyAuthorization }

        items.append(ProbeItem(
            "location.auth.initial",
            "Authorization at probe start",
            LocationProbeFmt.status(for: startStatus),
            value: LocationProbeFmt.auth(startStatus),
            detail: "Status BEFORE this run asked for anything. Recorded separately from "
                  + "the post-request status on purpose: the delta is the finding — it "
                  + "tells you whether a grant already survived from a previous launch "
                  + "or had to be re-obtained.",
            extra: [
                "rawValue": "\(startStatus.rawValue)",
                "accuracyAuthorization": LocationProbeFmt.accuracy(startAccuracy)
            ]))

        // --- When In Use -------------------------------------------------
        var whenInUseStatus = startStatus
        var whenInUsePrompted = false
        var whenInUseElapsed: Double = 0

        if startStatus == .notDetermined {
            whenInUsePrompted = true
            let t0 = Date()
            await session.onMain { $0.requestWhenInUseAuthorization() }
            // 45 s: long enough for a human to read a sheet, short enough that
            // an ignored prompt still leaves budget for the other 25 items.
            let resolved = await session.awaitAuthChange(from: .notDetermined, timeout: 45)
            whenInUseElapsed = Date().timeIntervalSince(t0)
            if let resolved {
                whenInUseStatus = resolved
            } else {
                // Timed out waiting on the delegate — read the truth directly.
                whenInUseStatus = await session.onMain { $0.authorizationStatus }
            }
        }

        items.append(ProbeItem(
            "location.auth.whenInUse",
            "requestWhenInUseAuthorization()",
            LocationProbeFmt.status(for: whenInUseStatus),
            value: LocationProbeFmt.auth(whenInUseStatus),
            detail: whenInUsePrompted
                ? "A system prompt was presented (status was notDetermined). Resolved in "
                  + String(format: "%.1f s", whenInUseElapsed) + "."
                : "No prompt shown — authorization was already decided before this run. "
                  + "CoreLocation will not re-prompt for a status it already holds; the "
                  + "only way back to notDetermined is deleting the app or resetting "
                  + "Settings › Privacy › Location Services.",
            extra: [
                "promptShown": whenInUsePrompted ? "true" : "false",
                "secondsToResolve": String(format: "%.2f", whenInUseElapsed),
                "rawValue": "\(whenInUseStatus.rawValue)"
            ]))

        // --- Always ------------------------------------------------------
        // Apple: "To obtain Always authorization, your app must first request
        // When In Use permission followed by requesting Always authorization."
        // and "Core Location limits calls to requestAlwaysAuthorization. After
        // your app calls this method, further calls have no effect."
        var alwaysStatus = whenInUseStatus
        var alwaysElapsed: Double = 0
        var alwaysAttempted = false

        if whenInUseStatus == .authorizedWhenInUse {
            alwaysAttempted = true
            let t0 = Date()
            await session.onMain { $0.requestAlwaysAuthorization() }
            let resolved = await session.awaitAuthChange(from: .authorizedWhenInUse, timeout: 20)
            alwaysElapsed = Date().timeIntervalSince(t0)
            if let resolved {
                alwaysStatus = resolved
            } else {
                // Silence is the answer: "Keep Only While Using" produces no
                // delegate callback at all, so read the status directly.
                alwaysStatus = await session.onMain { $0.authorizationStatus }
            }
        } else {
            alwaysStatus = await session.onMain { $0.authorizationStatus }
        }

        // Distinguish the two documented shapes of the Always upgrade.
        let alwaysDetail: String
        if !alwaysAttempted {
            alwaysDetail = "Not attempted: requestAlwaysAuthorization() is only legal from "
                         + "notDetermined or authorizedWhenInUse, and the status was "
                         + LocationProbeFmt.auth(whenInUseStatus) + "."
        } else if alwaysStatus == .authorizedAlways && alwaysElapsed < 1.5 {
            alwaysDetail = "Upgraded to authorizedAlways in "
                         + String(format: "%.2f s", alwaysElapsed)
                         + " — too fast for a human tap, i.e. PROVISIONAL Always. iOS "
                         + "granted it without showing a second sheet and DEFERS the real "
                         + "user-facing confirmation until the app actually uses location "
                         + "in the background. Architecturally this means a background "
                         + "collector can be silently downgraded later, days after install."
        } else if alwaysStatus == .authorizedAlways {
            alwaysDetail = "A SECOND system prompt was presented and the user chose "
                         + "'Change to Always Allow'. Resolved in "
                         + String(format: "%.1f s", alwaysElapsed)
                         + ". Note the first sheet only offers When In Use — Always is "
                         + "always a two-prompt flow on a fresh install."
        } else if alwaysStatus == .authorizedWhenInUse {
            alwaysDetail = "Status stayed authorizedWhenInUse after "
                         + String(format: "%.1f s", alwaysElapsed)
                         + ". Either the user chose 'Keep Only While Using' (in which case "
                         + "the delegate receives no update at all — the silence IS the "
                         + "answer), or the original grant was 'Allow Once', which Apple "
                         + "documents as causing Core Location to ignore all further "
                         + "requestAlwaysAuthorization() calls."
        } else {
            alwaysDetail = "Ended at " + LocationProbeFmt.auth(alwaysStatus) + " after "
                         + String(format: "%.1f s", alwaysElapsed) + "."
        }

        items.append(ProbeItem(
            "location.auth.always",
            "requestAlwaysAuthorization()",
            LocationProbeFmt.status(for: alwaysStatus),
            value: LocationProbeFmt.auth(alwaysStatus),
            detail: alwaysDetail,
            extra: [
                "attempted": alwaysAttempted ? "true" : "false",
                "secondsToResolve": String(format: "%.2f", alwaysElapsed),
                "secondPromptDeferred": (alwaysAttempted && alwaysStatus == .authorizedAlways && alwaysElapsed < 1.5) ? "true" : "false",
                "rawValue": "\(alwaysStatus.rawValue)",
                "delegateAuthCallbacks": "\(session.authCallbacks())"
            ]))

        let finalStatus = alwaysStatus
        let granted = (finalStatus == .authorizedAlways || finalStatus == .authorizedWhenInUse)

        // --- Accuracy ----------------------------------------------------
        let accuracy = await session.onMain { $0.accuracyAuthorization }
        items.append(ProbeItem(
            "location.auth.accuracy",
            "Accuracy authorization",
            accuracy == .fullAccuracy ? .ok : .partial,
            value: LocationProbeFmt.accuracy(accuracy),
            detail: accuracy == .fullAccuracy
                ? "Precise Location is ON. Fixes carry real horizontalAccuracy."
                : "Precise Location is OFF — iOS returns a ~1–20 km fuzzed region and "
                  + "region monitoring/visits degrade badly. Upgrading requires "
                  + "requestTemporaryFullAccuracyAuthorization(withPurposeKey:), which "
                  + "needs an NSLocationTemporaryUsageDescriptionDictionary entry in "
                  + "Info.plist; that key is NOT present in this build, so the upgrade "
                  + "path is deliberately not exercised here.",
            extra: ["rawValue": "\(accuracy.rawValue)"]))

        // ---------------------------------------------------------------
        // 2. One live fix
        // ---------------------------------------------------------------
        var fixCoordinate: CLLocationCoordinate2D?

        if granted {
            let outcome = await session.requestOneFix(timeout: 15)
            switch outcome {
            case .got(let loc):
                fixCoordinate = loc.coordinate
                var extra: [String: String] = [
                    "latitude3dp": String(format: "%.3f", loc.coordinate.latitude),
                    "longitude3dp": String(format: "%.3f", loc.coordinate.longitude),
                    "horizontalAccuracyMeters": String(format: "%.2f", loc.horizontalAccuracy),
                    "verticalAccuracyMeters": String(format: "%.2f", loc.verticalAccuracy),
                    "altitudeMeters": String(format: "%.2f", loc.altitude),
                    "ellipsoidalAltitudeMeters": String(format: "%.2f", loc.ellipsoidalAltitude),
                    "speedMetersPerSecond": String(format: "%.2f", loc.speed),
                    "speedAccuracy": String(format: "%.2f", loc.speedAccuracy),
                    "courseDegrees": String(format: "%.2f", loc.course),
                    "courseAccuracy": String(format: "%.2f", loc.courseAccuracy),
                    "timestamp": ProbeEnv.stamp(loc.timestamp) ?? "?",
                    "age": ProbeEnv.age(loc.timestamp) ?? "?",
                    "floor": loc.floor.map { "\($0.level)" } ?? "nil"
                ]
                if let src = loc.sourceInformation {
                    extra["source.isSimulatedBySoftware"] = src.isSimulatedBySoftware ? "true" : "false"
                    extra["source.isProducedByAccessory"] = src.isProducedByAccessory ? "true" : "false"
                } else {
                    extra["source"] = "nil (iOS did not attach CLLocationSourceInformation)"
                }

                var lines: [String] = []
                lines.append("Coordinate is TRUNCATED to 3 decimal places before it enters this "
                           + "report — about 110 m of latitude and 85 m of longitude at 40°N. "
                           + "The raw fix is never written to disk or to the JSON. That is "
                           + "redaction for shareability, not anonymisation: a 110 m box still "
                           + "resolves to a city block.")
                lines.append("horizontalAccuracy " + LocationProbeFmt.m(loc.horizontalAccuracy)
                           + " · verticalAccuracy " + LocationProbeFmt.m(loc.verticalAccuracy))
                lines.append("altitude (orthometric, MSL) " + LocationProbeFmt.m(loc.altitude)
                           + " · ellipsoidalAltitude (WGS84, iOS 15+) "
                           + LocationProbeFmt.m(loc.ellipsoidalAltitude)
                           + " — the gap between the two is the local geoid separation.")
                if loc.speed < 0 {
                    lines.append("speed is -1 → invalid. A one-shot requestLocation() rarely "
                               + "produces a valid speed/course; those need continuous updates.")
                } else {
                    lines.append(String(format: "speed %.2f m/s (±%.2f) · course %.2f° (±%.2f)",
                                        loc.speed, loc.speedAccuracy, loc.course, loc.courseAccuracy))
                }
                lines.append(loc.floor.map { "floor.level \($0.level) — this device resolved an indoor floor." }
                             ?? "floor is nil — no indoor floor plan covers this position.")
                if let src = loc.sourceInformation {
                    lines.append("sourceInformation: isSimulatedBySoftware="
                               + (src.isSimulatedBySoftware ? "true" : "false")
                               + ", isProducedByAccessory="
                               + (src.isProducedByAccessory ? "true" : "false")
                               + ". A collector MUST check isSimulatedBySoftware — Xcode "
                               + "location simulation and third-party spoofers both set it.")
                } else {
                    lines.append("sourceInformation is nil — iOS only attaches it when the fix "
                               + "is simulated or accessory-produced, so nil is the normal "
                               + "case for a genuine on-device fix.")
                }

                items.append(ProbeItem(
                    "location.fix",
                    "Live one-shot fix",
                    .ok,
                    value: LocationProbeFmt.coord(loc.coordinate) + " (±"
                         + ProbeEnv.num(loc.horizontalAccuracy) + " m)",
                    detail: lines.joined(separator: "\n"),
                    extra: extra))

            case .failed(let e):
                items.append(ProbeItem(
                    "location.fix", "Live one-shot fix", .error,
                    value: "failed",
                    detail: "requestLocation() reported " + LocationProbeFmt.clError(e)
                          + ". CLError.locationUnknown is usually transient (indoors, cold "
                          + "start); CLError.denied means Location Services is off system-wide.",
                    extra: ["error": LocationProbeFmt.clError(e)]))

            case .timedOut:
                let failures = session.locationFailureList()
                items.append(ProbeItem(
                    "location.fix", "Live one-shot fix", .empty,
                    value: "no fix within 15 s",
                    detail: "requestLocation() neither delivered a location nor failed inside "
                          + "15 s. That is a real result: GPS cold start indoors regularly "
                          + "exceeds this. A background collector must treat 'no fix' as a "
                          + "normal state, not an error."
                          + (failures.isEmpty ? "" : "\nDelegate errors seen: "
                             + failures.joined(separator: " | ")),
                    extra: [
                        "timeoutSeconds": "15",
                        "delegateErrorCount": "\(failures.count)"
                    ]))
            }
        } else {
            items.append(ProbeItem(
                "location.fix", "Live one-shot fix",
                finalStatus == .notDetermined ? .notDetermined : .denied,
                value: "not attempted",
                detail: "Authorization ended at " + LocationProbeFmt.auth(finalStatus)
                      + ", so no fix was requested."))
        }

        // Cached last-known location — free, and tells you how stale iOS's own
        // cache is at the moment a background wake would read it.
        let cached = await session.onMain { $0.location }
        if let c = cached {
            items.append(ProbeItem(
                "location.cached", "manager.location (cached)", .ok,
                value: LocationProbeFmt.coord(c.coordinate) + " · " + (ProbeEnv.age(c.timestamp) ?? "?"),
                detail: "The location a relaunched app can read INSTANTLY with zero power "
                      + "cost, before starting any service. Its age is the number that "
                      + "matters for a background collector.",
                extra: [
                    "timestamp": ProbeEnv.stamp(c.timestamp) ?? "?",
                    "age": ProbeEnv.age(c.timestamp) ?? "?",
                    "horizontalAccuracyMeters": String(format: "%.2f", c.horizontalAccuracy)
                ]))
        } else {
            items.append(ProbeItem(
                "location.cached", "manager.location (cached)", .empty,
                value: "nil",
                detail: "No cached location. Expected when authorization was just granted "
                      + "or Location Services has been off."))
        }

        // ---------------------------------------------------------------
        // 3. Capability flags — one item each
        // ---------------------------------------------------------------
        // locationServicesEnabled() blocks on an XPC round trip; Apple warns
        // that calling it on the main thread can hang the UI. Forced onto a
        // background queue here.
        let servicesEnabled: Bool = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                c.resume(returning: CLLocationManager.locationServicesEnabled())
            }
        }
        items.append(ProbeItem(
            "location.cap.servicesEnabled", "locationServicesEnabled()",
            servicesEnabled ? .ok : .denied,
            value: servicesEnabled ? "true" : "false",
            detail: "Called OFF the main thread deliberately. On the main thread this class "
                  + "method makes a synchronous XPC call and iOS logs a UI-unresponsiveness "
                  + "warning; under load it can genuinely hang. This is a SYSTEM-WIDE switch "
                  + "and is independent of the app's own authorization — the two disagree "
                  + "constantly and both must be checked.",
            extra: ["calledOnMainThread": "false"]))

        let slc = CLLocationManager.significantLocationChangeMonitoringAvailable()
        items.append(ProbeItem(
            "location.cap.significantChange", "significantLocationChangeMonitoringAvailable()",
            slc ? .ok : .unavailable,
            value: slc ? "true" : "false",
            detail: "Cell-tower based, ~500 m / ~5 min granularity, near-zero power. Apple: "
                  + "\"If you start this service and your app is subsequently terminated, the "
                  + "system automatically relaunches the app into the background if a new "
                  + "event arrives.\" Not started by this probe — it would leave a persistent "
                  + "service running after the report finishes."))

        let circular = CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self)
        items.append(ProbeItem(
            "location.cap.circularRegion", "isMonitoringAvailable(for: CLCircularRegion.self)",
            circular ? .ok : .unavailable,
            value: circular ? "true" : "false",
            detail: "Classic geofencing. CLCircularRegion and startMonitoring(for:) are marked "
                  + "deprecated as of iOS 27 — they still compile and run on the iOS 26 SDK, "
                  + "but CLMonitor.CircularGeographicCondition is the forward path."))

        let beacon = CLLocationManager.isMonitoringAvailable(for: CLBeaconRegion.self)
        items.append(ProbeItem(
            "location.cap.beaconRegion", "isMonitoringAvailable(for: CLBeaconRegion.self)",
            beacon ? .ok : .unavailable,
            value: beacon ? "true" : "false",
            detail: "iBeacon region monitoring. Also deprecated as of iOS 27; the replacement "
                  + "is CLMonitor.BeaconIdentityCondition."))

        let ranging = CLLocationManager.isRangingAvailable()
        items.append(ProbeItem(
            "location.cap.ranging", "isRangingAvailable()",
            ranging ? .ok : .unavailable,
            value: ranging ? "true" : "false",
            detail: "Beacon RANGING (continuous distance estimate), distinct from beacon "
                  + "monitoring (enter/exit). Ranging is foreground-only and does not "
                  + "relaunch a terminated app."))

        let headingAvail = CLLocationManager.headingAvailable()
        items.append(ProbeItem(
            "location.cap.heading", "headingAvailable()",
            headingAvail ? .ok : .unavailable,
            value: headingAvail ? "true" : "false",
            detail: "Magnetometer-backed compass. Sampled below if true."))

        let deferred = CLLocationManager.deferredLocationUpdatesAvailable()
        items.append(ProbeItem(
            "location.cap.deferred", "deferredLocationUpdatesAvailable()",
            deferred ? .ok : .unavailable,
            value: deferred ? "true" : "false",
            detail: "Deprecated since iOS 13 with Apple's own note \"You can remove calls to "
                  + "this method\". It has effectively returned false since iOS 10 — a false "
                  + "here is the EXPECTED ground truth, not a device limitation. Batching "
                  + "location updates to save power is no longer a thing you can ask for.",
            extra: ["deprecatedIn": "iOS 13.0", "effectivelyDeadSince": "iOS 10"]))

        // ---------------------------------------------------------------
        // 4. Visits + background updates
        // ---------------------------------------------------------------
        if granted {
            await session.onMain { $0.startMonitoringVisits() }
            // Give any immediately-queued visit a moment to land.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let sampled = session.visitSamples()

            items.append(ProbeItem(
                "location.visits.monitoring", "startMonitoringVisits()", .ok,
                value: "started",
                detail: "CLVisit is the centrepiece of a life log: arrival/departure at places "
                      + "at near-zero marginal power, because it rides the same cell/Wi-Fi "
                      + "machinery iOS already runs. Apple: \"If your app is terminated while "
                      + "this service is active, the system relaunches your app when new visit "
                      + "events are ready to be delivered.\" DELIBERATELY LEFT RUNNING after "
                      + "this probe so the relaunch path can be observed later.",
                extra: ["leftRunning": "true"]))

            if let v = sampled.first {
                items.append(ProbeItem(
                    "location.visits.sample", "Live CLVisit sample", .ok,
                    value: LocationProbeFmt.coord(v.coordinate),
                    detail: "A visit arrived during the probe run — unusual and worth noting.",
                    extra: [
                        "arrival": ProbeEnv.stamp(v.arrivalDate) ?? "distantPast",
                        "departure": ProbeEnv.stamp(v.departureDate) ?? "distantFuture",
                        "horizontalAccuracyMeters": String(format: "%.2f", v.horizontalAccuracy),
                        "count": "\(sampled.count)"
                    ]))
            } else {
                items.append(ProbeItem(
                    "location.visits.sample", "Live CLVisit sample", .empty,
                    value: "none in 1.5 s (expected)",
                    detail: "Visits arrive over HOURS, not seconds — iOS only emits one once it "
                      + "is confident the user has settled at, or left, a place. A live sample "
                      + "during a probe run is not expected and its absence is not a failure.\n"
                      + "MEASURED NEGATIVE: CoreLocation exposes NO CLVisit history API. There "
                      + "is no query, no date-range fetch, no backfill — the framework is "
                      + "strictly forward-only, so a collector gets exactly the visits that "
                      + "occur while it is registered and nothing from before. The only "
                      + "historical visit store on iOS is SensorKit's SRSensorVisits, which "
                      + "needs an Apple-granted research entitlement (probed separately in "
                      + "the entitlements section).",
                    extra: [
                        "historyApiExists": "false",
                        "backfillWindowSeconds": "0",
                        "historicalAlternative": "SensorKit SRSensorVisits (entitlement-gated)",
                        "waitedSeconds": "1.5"
                    ]))
            }
        } else {
            items.append(ProbeItem(
                "location.visits.monitoring", "startMonitoringVisits()",
                finalStatus == .notDetermined ? .notDetermined : .denied,
                value: "not started",
                detail: "Requires location authorization; status is "
                      + LocationProbeFmt.auth(finalStatus) + "."))
        }

        // --- allowsBackgroundLocationUpdates ------------------------------
        // This is a REAL crash source and the reason it is checked this way:
        // Apple documents that "Setting the value to true but omitting the
        // UIBackgroundModes key and location value in your app's Info.plist
        // file is a fatal error that terminates the app." A trap cannot be
        // caught, so we read the Info.plist FIRST and only set the flag when
        // the mode is provably declared.
        let modes = (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]) ?? []
        let hasLocationMode = modes.contains("location")

        items.append(ProbeItem(
            "location.background.mode", "UIBackgroundModes contains \"location\"",
            hasLocationMode ? .ok : .unavailable,
            value: hasLocationMode ? "true" : "false",
            detail: "Read from the built Info.plist at runtime, not assumed. This single bit "
                  + "decides whether the next item is safe to execute at all.",
            extra: ["declaredModes": modes.isEmpty ? "<none>" : modes.joined(separator: ", ")]))

        if hasLocationMode {
            let readBack = await session.onMain { (m: CLLocationManager) -> Bool in
                m.allowsBackgroundLocationUpdates = true
                return m.allowsBackgroundLocationUpdates
            }
            let indicator = await session.onMain { (m: CLLocationManager) -> Bool in
                m.showsBackgroundLocationIndicator = true
                return m.showsBackgroundLocationIndicator
            }
            // Put both back: leaving them on would raise the blue background-
            // location indicator during the brief startUpdatingLocation() used
            // for the heading sample. The probe leaves no state it did not find.
            await session.onMain { (m: CLLocationManager) in
                m.allowsBackgroundLocationUpdates = false
                m.showsBackgroundLocationIndicator = false
            }
            items.append(ProbeItem(
                "location.background.allowsBackgroundLocationUpdates",
                "allowsBackgroundLocationUpdates = true",
                readBack ? .ok : .error,
                value: readBack ? "true (set and read back)" : "set but read back false",
                detail: "CONFIRMED SAFE ON THIS BUILD. Apple: \"Setting the value to true but "
                      + "omitting the UIBackgroundModes key and location value in your app's "
                      + "Info.plist file is a fatal error that terminates the app.\" The "
                      + "resulting NSInternalInconsistencyException (\"Invalid parameter not "
                      + "satisfying: !stayUp || CLClientIsBackgroundable\") is a trap, not a "
                      + "throw — it cannot be caught, so the Info.plist was checked first. "
                      + "Note the flag is NOT required for significant-change, visits or "
                      + "region monitoring; only continuous startUpdatingLocation needs it, "
                      + "and only that mode raises the blue indicator.",
                extra: [
                    "showsBackgroundLocationIndicator": indicator ? "true" : "false",
                    "requiredForVisitsOrSLC": "false",
                    "restoredToFalseAfterProbe": "true"
                ]))
        } else {
            items.append(ProbeItem(
                "location.background.allowsBackgroundLocationUpdates",
                "allowsBackgroundLocationUpdates = true",
                .unavailable,
                value: "deliberately not attempted",
                detail: "UIBackgroundModes does not declare \"location\", and Apple documents "
                      + "that setting this flag without it is \"a fatal error that terminates "
                      + "the app\". That is an uncatchable trap, so the assignment was skipped "
                      + "rather than risk losing the entire report."))
        }

        // ---------------------------------------------------------------
        // 5. Region monitoring
        // ---------------------------------------------------------------
        let maxRegionDistance = await session.onMain { $0.maximumRegionMonitoringDistance }
        items.append(ProbeItem(
            "location.region.maxDistance", "maximumRegionMonitoringDistance",
            maxRegionDistance > 0 ? .ok : .unavailable,
            value: LocationProbeFmt.m(maxRegionDistance),
            detail: "Largest allowed radius from a region's centre on THIS device. A larger "
                  + "radius makes the manager deliver a regionMonitoringFailure to the "
                  + "delegate. Apple documents this as -1 when region monitoring is "
                  + "unsupported.",
            extra: ["meters": String(format: "%.1f", maxRegionDistance)]))

        items.append(ProbeItem(
            "location.region.cap", "Per-app geofence cap", .ok,
            value: "20 regions",
            detail: "Verified against Apple's own text on startMonitoring(for:): \"An app can "
                  + "register up to 20 regions at a time.\" The cap is per APP, not per "
                  + "CLLocationManager — monitoredRegions is shared by every manager instance "
                  + "in the process and persists across launches. CLMonitor carries the same "
                  + "limit of 20 simultaneous conditions. This is the hard ceiling any "
                  + "place-based collector has to design around: 20 slots means you must "
                  + "swap geofences dynamically as the user moves.",
            extra: [
                "maxRegionsPerApp": "20",
                "maxCLMonitorConditions": "20",
                "scope": "per app, shared across all CLLocationManager instances, persistent",
                "source": "developer.apple.com CLLocationManager.startMonitoring(for:)"
            ]))

        if granted, circular, let center = fixCoordinate, maxRegionDistance > 0 {
            let radius = min(150.0, maxRegionDistance)
            let identifier = "LocationProbe.testGeofence"
            let region = CLCircularRegion(center: center, radius: radius, identifier: identifier)
            region.notifyOnEntry = true
            region.notifyOnExit = true

            await session.onMain { $0.startMonitoring(for: region) }
            // Registration is asynchronous; poll rather than guess.
            var registered = false
            var monitoredCount = 0
            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                let regions = await session.onMain { $0.monitoredRegions }
                monitoredCount = regions.count
                if regions.contains(where: { $0.identifier == identifier }) {
                    registered = true
                    break
                }
            }
            let failures = session.regionFailureList()
            let events = session.regionEventList()

            let regionStatus: ProbeStatus
            if registered { regionStatus = .ok }
            else if failures.isEmpty { regionStatus = .empty }
            else { regionStatus = .error }

            var regionValue = "not present in monitoredRegions"
            if registered {
                regionValue = "registered · r=\(Int(radius)) m · centre "
                regionValue += LocationProbeFmt.coord(center)
            }

            var rd = ""
            if registered {
                rd += "A \(Int(radius)) m CLCircularRegion was registered around the current "
                rd += "fix and confirmed present in monitoredRegions, then REMOVED so nothing "
                rd += "persists. The centre shown here is truncated to 3 dp like every other "
                rd += "coordinate in this report."
            } else {
                rd += "startMonitoring(for:) was called but the region never appeared in "
                rd += "monitoredRegions within 3 s."
            }
            if !failures.isEmpty {
                rd += "\nDelegate failures: " + failures.joined(separator: " | ")
            }
            if !events.isEmpty {
                rd += "\nDelegate events: " + events.joined(separator: " | ")
            }
            rd += "\nApple's guidance: radii between 1 and 400 m behave best, and entry/exit "
            rd += "callbacks typically arrive within 3–5 minutes — geofences are NOT "
            rd += "instantaneous and region monitoring requires network connectivity."

            items.append(ProbeItem(
                "location.region.test", "Test geofence registration",
                regionStatus,
                value: regionValue,
                detail: rd,
                extra: [
                    "radiusMeters": String(format: "%.0f", radius),
                    "monitoredRegionsCount": "\(monitoredCount)",
                    "registered": registered ? "true" : "false",
                    "delegateFailures": "\(failures.count)",
                    "cleanedUp": "true"
                ]))

            await session.onMain { $0.stopMonitoring(for: region) }
        } else {
            let skipStatus: ProbeStatus
            if granted { skipStatus = .empty }
            else if finalStatus == .notDetermined { skipStatus = .notDetermined }
            else { skipStatus = .denied }

            var sd = ""
            if fixCoordinate == nil {
                sd += "No live fix was obtained, so there was no safe centre for a test "
                sd += "geofence. Registering one at a guessed coordinate would be noise."
            } else {
                sd += "Region monitoring unavailable or authorization insufficient ("
                sd += LocationProbeFmt.auth(finalStatus) + ")."
            }

            items.append(ProbeItem(
                "location.region.test", "Test geofence registration",
                skipStatus,
                value: "not attempted",
                detail: sd))
        }

        // ---------------------------------------------------------------
        // 6. iOS 17+ modern API
        // ---------------------------------------------------------------
        let modern = await modernItems(granted: granted, center: fixCoordinate)
        items.append(contentsOf: modern)

        // ---------------------------------------------------------------
        // 7. Heading
        // ---------------------------------------------------------------
        if headingAvail && granted {
            // trueHeading is only computed while location updates are running;
            // without this you get magneticHeading and trueHeading == -1.
            await session.onMain {
                $0.headingFilter = kCLHeadingFilterNone
                $0.headingOrientation = .portrait
                $0.startUpdatingLocation()
                $0.startUpdatingHeading()
            }
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            let h = session.heading()
            await session.onMain {
                $0.stopUpdatingHeading()
                $0.stopUpdatingLocation()
            }

            if let h {
                let trueValid = h.trueHeading >= 0
                let trueText = trueValid ? String(format: "%.1f°", h.trueHeading) : "invalid (-1)"
                let magText = String(format: "%.1f°", h.magneticHeading)
                let accText = String(format: "%.1f°", h.headingAccuracy)

                var hd = ""
                hd += "Sampled for 2.2 s with continuous location updates running — "
                hd += "trueHeading is ONLY computed while location services are active, "
                hd += "which is why a compass-only app gets -1 forever.\n"
                if h.headingAccuracy < 0 {
                    hd += "headingAccuracy is negative → the reading is unreliable and iOS "
                    hd += "wants a figure-8 calibration. The calibration HUD was suppressed "
                    hd += "by the delegate so it could not hijack the probe UI."
                } else {
                    hd += "headingAccuracy ±\(accText) — lower is better; iOS reports this "
                    hd += "as a magnetic deviation estimate."
                }
                hd += "\nRaw magnetometer components are in microteslas and include the "
                hd += "device's own magnetic bias."

                items.append(ProbeItem(
                    "location.heading.sample", "Live heading sample",
                    h.headingAccuracy >= 0 ? .ok : .partial,
                    value: "magnetic \(magText) · true \(trueText)",
                    detail: hd,
                    extra: [
                        "magneticHeadingDegrees": String(format: "%.2f", h.magneticHeading),
                        "trueHeadingDegrees": String(format: "%.2f", h.trueHeading),
                        "trueHeadingValid": trueValid ? "true" : "false",
                        "headingAccuracyDegrees": String(format: "%.2f", h.headingAccuracy),
                        "x_uT": String(format: "%.3f", h.x),
                        "y_uT": String(format: "%.3f", h.y),
                        "z_uT": String(format: "%.3f", h.z),
                        "timestamp": ProbeEnv.stamp(h.timestamp) ?? "?"
                    ]))
            } else {
                items.append(ProbeItem(
                    "location.heading.sample", "Live heading sample", .empty,
                    value: "no heading in 2.2 s",
                    detail: "headingAvailable() returned true but no didUpdateHeading callback "
                          + "arrived. Usually means the magnetometer needs calibration or the "
                          + "device is near a strong magnetic field.",
                    extra: ["waitedSeconds": "2.2"]))
            }
        } else {
            items.append(ProbeItem(
                "location.heading.sample", "Live heading sample",
                headingAvail ? (finalStatus == .notDetermined ? .notDetermined : .denied) : .unavailable,
                value: "not attempted",
                detail: headingAvail
                    ? "Requires location authorization; status is " + LocationProbeFmt.auth(finalStatus) + "."
                    : "headingAvailable() is false — no magnetometer on this device."))
        }

        // ---------------------------------------------------------------
        // 8. Reverse geocode
        // ---------------------------------------------------------------
        let geo = await geocodeItem(coordinate: fixCoordinate, granted: granted)
        items.append(geo)

        // ---------------------------------------------------------------
        // Summary
        // ---------------------------------------------------------------
        let summary = buildSummary(finalStatus: finalStatus,
                                   accuracy: accuracy,
                                   servicesEnabled: servicesEnabled,
                                   gotFix: fixCoordinate != nil,
                                   hasLocationMode: hasLocationMode,
                                   maxRegionDistance: maxRegionDistance)

        return section(summary, items)
    }

    // MARK: - iOS 17+ modern API

    private func modernItems(granted: Bool,
                             center: CLLocationCoordinate2D?) async -> [ProbeItem] {
        var out: [ProbeItem] = []

        // --- CLLocationUpdate.liveUpdates() -------------------------------
        if granted {
            let r: LocationProbeLiveResult = await LocationProbeRace.run(
                12, fallback: LocationProbeLiveResult()
            ) {
                var res = LocationProbeLiveResult()
                do {
                    for try await update in CLLocationUpdate.liveUpdates(.default) {
                        res.arrived = true
                        res.stationary = update.isStationary
                        if #available(iOS 18, *) {
                            res.flags["accuracyLimited"] = update.accuracyLimited ? "true" : "false"
                            res.flags["authorizationDenied"] = update.authorizationDenied ? "true" : "false"
                            res.flags["authorizationDeniedGlobally"] = update.authorizationDeniedGlobally ? "true" : "false"
                            res.flags["authorizationRequestInProgress"] = update.authorizationRequestInProgress ? "true" : "false"
                            res.flags["authorizationRestricted"] = update.authorizationRestricted ? "true" : "false"
                            res.flags["insufficientlyInUse"] = update.insufficientlyInUse ? "true" : "false"
                            res.flags["locationUnavailable"] = update.locationUnavailable ? "true" : "false"
                            res.flags["serviceSessionRequired"] = update.serviceSessionRequired ? "true" : "false"
                        }
                        if let loc = update.location {
                            res.coord = loc.coordinate
                            res.accuracy = loc.horizontalAccuracy
                            res.timestamp = loc.timestamp
                            break
                        }
                        // A location-less update is still a real signal (stationary,
                        // or an iOS 18 condition flag). Take one and stop.
                        if !res.flags.isEmpty || res.stationary { break }
                    }
                } catch {
                    res.error = LocationProbeFmt.clError(error)
                }
                return res
            }

            var extra: [String: String] = [
                "isStationary": r.stationary ? "true" : "false",
                "updateArrived": r.arrived ? "true" : "false",
                "waitedSeconds": "12"
            ]
            for (k, v) in r.flags { extra["flag." + k] = v }
            if let t = r.timestamp { extra["timestamp"] = ProbeEnv.stamp(t) ?? "?" }
            if let c = r.coord {
                extra["latitude3dp"] = String(format: "%.3f", c.latitude)
                extra["longitude3dp"] = String(format: "%.3f", c.longitude)
                extra["horizontalAccuracyMeters"] = String(format: "%.2f", r.accuracy)
            }

            let serviceSessionRequired = r.flags["serviceSessionRequired"] == "true"

            let liveStatus: ProbeStatus
            if r.error != nil { liveStatus = .error }
            else if r.coord != nil { liveStatus = .ok }
            else if r.arrived { liveStatus = .partial }
            else { liveStatus = .empty }

            var liveValue: String
            if r.error != nil {
                liveValue = "threw"
            } else if let c = r.coord {
                liveValue = LocationProbeFmt.coord(c)
                liveValue += " (±"
                liveValue += ProbeEnv.num(r.accuracy)
                liveValue += " m)"
            } else if r.arrived {
                liveValue = "update with no location"
            } else {
                liveValue = "no update in 12 s"
            }

            var liveDetail = ""
            if let e = r.error { liveDetail += "Iteration threw: \(e)\n" }
            liveDetail += "The iOS 17 AsyncSequence replacement for startUpdatingLocation + "
            liveDetail += "delegate. It RESOLVES and iterates on this device. Two things a "
            liveDetail += "collector must know: (a) it is foreground/live only — it does NOT "
            liveDetail += "relaunch a terminated app, so it can never be the backbone of a "
            liveDetail += "background log; (b) the sequence does not necessarily honour "
            liveDetail += "cancellation promptly, which is why this probe races it against an "
            liveDetail += "independent deadline rather than relying on task-group cancellation."
            if serviceSessionRequired {
                liveDetail += "\nMEASURED: serviceSessionRequired is TRUE — on iOS 18+ an app "
                liveDetail += "with Always authorization must hold an explicit CLServiceSession "
                liveDetail += "(or a CLBackgroundActivitySession) or the stream delivers "
                liveDetail += "nothing. This is the most common iOS 18 location regression."
            }
            if r.flags.isEmpty {
                liveDetail += "\nThe iOS 18 condition flags (serviceSessionRequired, "
                liveDetail += "insufficientlyInUse, accuracyLimited, …) were not read because "
                liveDetail += "this device is on iOS 17."
            }

            out.append(ProbeItem(
                "location.modern.liveUpdates", "CLLocationUpdate.liveUpdates()",
                liveStatus,
                value: liveValue,
                detail: liveDetail,
                extra: extra))
        } else {
            out.append(ProbeItem(
                "location.modern.liveUpdates", "CLLocationUpdate.liveUpdates()",
                .notDetermined,
                value: "type resolves; not exercised",
                detail: "CLLocationUpdate exists on this OS but was not iterated because "
                      + "authorization was not granted."))
        }

        // --- CLBackgroundActivitySession ----------------------------------
        let bgSession = CLBackgroundActivitySession()
        bgSession.invalidate()
        out.append(ProbeItem(
            "location.modern.backgroundActivitySession", "CLBackgroundActivitySession",
            .ok,
            value: "instantiated and invalidated",
            detail: "iOS 17's explicit, user-visible background-location grant: while a session "
                  + "is alive the system shows the location indicator and keeps delivering "
                  + "updates in the background. Two traps: the object must be STRONGLY HELD — "
                  + "deallocation implicitly invalidates it and background access dies "
                  + "silently — and on iOS 18+ an Always-authorized app needs a session (or a "
                  + "CLServiceSession) for CLLocationUpdate/CLMonitor to deliver at all. "
                  + "Invalidated immediately here so the probe leaves no indicator running.",
            extra: ["mustBeRetained": "true", "invalidatedByProbe": "true"]))

        // --- CLMonitor.CircularGeographicCondition (pure value, always safe)
        if let c = center {
            let cond = CLMonitor.CircularGeographicCondition(center: c, radius: 150)
            out.append(ProbeItem(
                "location.modern.condition", "CLMonitor.CircularGeographicCondition",
                .ok,
                value: "constructed · r=\(Int(cond.radius)) m · centre \(LocationProbeFmt.coord(cond.center))",
                detail: "The iOS 17 replacement for CLCircularRegion. It is Codable and "
                      + "Sendable, which is the real upgrade: conditions can be persisted and "
                      + "swapped in the background as the user moves, instead of being pinned "
                      + "at registration time. Same 20-condition ceiling as the old API.",
                extra: [
                    "radiusMeters": String(format: "%.0f", cond.radius),
                    "codable": "true",
                    "replaces": "CLCircularRegion"
                ]))
        } else {
            out.append(ProbeItem(
                "location.modern.condition", "CLMonitor.CircularGeographicCondition",
                .empty,
                value: "type resolves; no centre available",
                detail: "No live fix, so no honest centre to construct a condition around."))
        }

        // --- CLMonitor (guarded: its async init has an open crash report) ---
        let (mayAttempt, priorUnfinished) = LocationProbeCrashGuard.shouldAttempt("clmonitor")
        if !mayAttempt {
            out.append(ProbeItem(
                "location.modern.clmonitor", "CLMonitor", .error,
                value: "skipped — killed the app on \(priorUnfinished) prior runs",
                detail: "A crash guard in UserDefaults recorded \(priorUnfinished) attempts that "
                      + "never completed, meaning await CLMonitor(_:) terminated this app. A "
                      + "trap cannot be caught, so it is now permanently skipped rather than "
                      + "risk the whole report. THIS IS A REAL FINDING for this device.",
                extra: ["unfinishedAttempts": "\(priorUnfinished)", "permanentlySkipped": "true"]))
        } else if !granted {
            LocationProbeCrashGuard.complete("clmonitor")
            out.append(ProbeItem(
                "location.modern.clmonitor", "CLMonitor", .notDetermined,
                value: "type resolves; not instantiated",
                detail: "CLMonitor requires location authorization to do anything useful; "
                      + "status was not granted."))
        } else {
            let mr: LocationProbeMonitorResult = await LocationProbeRace.run(
                12, fallback: LocationProbeMonitorResult()
            ) {
                var res = LocationProbeMonitorResult()
                let monitor = await CLMonitor("LocationProbe.monitor")
                res.created = true
                if let c = center {
                    let id = "LocationProbe.condition"
                    let cond = CLMonitor.CircularGeographicCondition(center: c, radius: 150)
                    await monitor.add(cond, identifier: id)
                    res.identifiers = await monitor.identifiers
                    if let rec = await monitor.record(for: id) {
                        res.recordState = String(describing: rec.lastEvent.state)
                    }
                    // MUST remove: CLMonitor conditions are persistent by design
                    // and survive app termination. Leaving one behind would park
                    // a permanent geofence on the owner's real location.
                    await monitor.remove(id)
                    res.removed = true
                } else {
                    res.note = "No fix, so no condition was added."
                }
                return res
            }
            LocationProbeCrashGuard.complete("clmonitor")

            // The 12 s race can cut the worker between add() and remove(), and
            // CLMonitor conditions are PERSISTENT — a leftover would park a
            // permanent geofence on the owner's real location, which is exactly
            // what the 3-dp truncation everywhere else in this file exists to
            // prevent. Re-entering the initialiser is proven safe here because
            // it already succeeded once this run.
            var cleanedUpLate = false
            if mr.created && !mr.removed {
                cleanedUpLate = await LocationProbeRace.run(6, fallback: false) {
                    let m = await CLMonitor("LocationProbe.monitor")
                    await m.remove("LocationProbe.condition")
                    return true
                }
            }

            let recordState = mr.recordState ?? "n/a"
            var monValue = "did not resolve within 12 s"
            if mr.created {
                monValue = "created · \(mr.identifiers.count) condition(s) · state \(recordState)"
            }

            var monDetail = ""
            if let n = mr.note { monDetail += "\(n)\n" }
            monDetail += "The modern replacement for region monitoring: an actor you add named "
            monDetail += "CLCondition objects to, and read events from as an AsyncSequence. "
            monDetail += "Conditions are PERSISTENT — they survive termination and relaunch the "
            monDetail += "app — so the probe removes its test condition again "
            if mr.removed {
                monDetail += "(confirmed removed)."
            } else if cleanedUpLate {
                monDetail += "(the timed race cut the worker before remove(); a second-pass "
                monDetail += "removal ran afterwards and succeeded)."
            } else {
                monDetail += "(removal NOT confirmed — check for a stray condition)."
            }
            monDetail += "\nProbed behind a UserDefaults crash guard because await CLMonitor(_:) "
            monDetail += "has an open, unresolved crash report on Apple's forums and a trap "
            monDetail += "cannot be caught. The guard detects process death during the call, so "
            monDetail += "it catches a trap inside the 12 s window but not one after it. Prior "
            monDetail += "unfinished attempts on this device: \(priorUnfinished)."
            monDetail += "\nInitial record state is normally 'unknown' until iOS evaluates the "
            monDetail += "condition, which takes minutes — an immediate 'satisfied' would be "
            monDetail += "the surprising result."

            out.append(ProbeItem(
                "location.modern.clmonitor", "CLMonitor",
                mr.created ? .ok : .error,
                value: monValue,
                detail: monDetail,
                extra: [
                    "identifiers": mr.identifiers.isEmpty ? "<none>" : mr.identifiers.joined(separator: ", "),
                    "conditionCount": "\(mr.identifiers.count)",
                    "lastEventState": mr.recordState ?? "nil",
                    "conditionRemoved": (mr.removed || cleanedUpLate) ? "true" : "false",
                    "removedOnSecondPass": cleanedUpLate ? "true" : "false",
                    "priorUnfinishedAttempts": "\(priorUnfinished)",
                    "maxConditions": "20"
                ]))
        }

        return out
    }

    // MARK: - Reverse geocoding

    private func geocodeItem(coordinate: CLLocationCoordinate2D?, granted: Bool) async -> ProbeItem {
        guard let coordinate else {
            return ProbeItem(
                "location.geocode", "CLGeocoder reverse geocode",
                granted ? .empty : .notDetermined,
                value: "not attempted",
                detail: "No live fix to reverse-geocode.")
        }

        let geocoder = CLGeocoder()
        // Built from the ALREADY-TRUNCATED coordinate, so the precise fix is
        // never sent to Apple's geocoding service either.
        let location = CLLocation(latitude: (coordinate.latitude * 1000).rounded() / 1000,
                                  longitude: (coordinate.longitude * 1000).rounded() / 1000)

        var timeoutFallback = LocationProbeGeoResult()
        timeoutFallback.timedOut = true

        let result: LocationProbeGeoResult = await LocationProbeRace.run(12, fallback: timeoutFallback) {
            await withCheckedContinuation { (c: CheckedContinuation<LocationProbeGeoResult, Never>) in
                let once = LocationProbeOnce()
                geocoder.reverseGeocodeLocation(location) { placemarks, error in
                    guard once.claim() else { return }
                    var g = LocationProbeGeoResult()
                    if let error {
                        g.error = LocationProbeFmt.clError(error)
                        if let cl = error as? CLError, cl.code == .network {
                            // kCLErrorNetwork is what CLGeocoder returns when the
                            // Apple geocoding service throttles the client.
                            g.rateLimited = true
                        }
                    }
                    if let p = placemarks?.first {
                        g.locality = p.locality
                        g.subAdmin = p.subAdministrativeArea
                        g.admin = p.administrativeArea
                        g.country = p.country
                        g.isoCountry = p.isoCountryCode
                        g.timeZone = p.timeZone?.identifier
                        g.inland = p.inlandWater
                        g.ocean = p.ocean
                    }
                    c.resume(returning: g)
                }
            }
        }
        if result.timedOut { geocoder.cancelGeocode() }

        let place = [result.locality, result.subAdmin, result.admin, result.isoCountry]
            .compactMap { $0 }
            .joined(separator: ", ")

        var extra: [String: String] = [
            "rateLimited": result.rateLimited ? "true" : "false",
            "timedOut": result.timedOut ? "true" : "false",
            "inputPrecision": "3 decimal places (truncated before the request)"
        ]
        if let v = result.locality { extra["locality"] = v }
        if let v = result.subAdmin { extra["subAdministrativeArea"] = v }
        if let v = result.admin { extra["administrativeArea"] = v }
        if let v = result.country { extra["country"] = v }
        if let v = result.isoCountry { extra["isoCountryCode"] = v }
        if let v = result.timeZone { extra["timeZone"] = v }
        if let v = result.inland { extra["inlandWater"] = v }
        if let v = result.ocean { extra["ocean"] = v }
        if let v = result.error { extra["error"] = v }

        let status: ProbeStatus
        if result.timedOut { status = .empty }
        else if result.rateLimited { status = .partial }
        else if result.error != nil && place.isEmpty { status = .error }
        else if place.isEmpty { status = .empty }
        else { status = .ok }

        var geoValue = place
        if place.isEmpty { geoValue = result.rateLimited ? "rate-limited" : "no placemark" }

        var d = ""
        d += "ONLY locality / county / state / country are reported. Street number, "
        d += "thoroughfare, postal code and the placemark's own name are deliberately "
        d += "dropped — at street granularity a reverse geocode of a home fix IS a home "
        d += "address, and this report is meant to be shareable.\n"
        d += "CLGeocoder is a SERVER call: it needs network, it is rate-limited per app, "
        d += "and Apple's throttle surfaces as CLError.network (2) rather than a dedicated "
        d += "code — so 'rateLimited' below is INFERRED from that code, not reported "
        d += "explicitly by the API. Apple's guidance is at most one request per user "
        d += "action and never in a loop, which rules CLGeocoder out as a batch enrichment "
        d += "step for a location log.\n"
        if result.rateLimited {
            d += "MEASURED: this request was throttled or the network was unavailable."
        } else if result.timedOut {
            d += "MEASURED: no response inside 12 s; the request was cancelled."
        } else {
            d += "MEASURED: the request completed."
        }
        d += "\nThe coordinate sent was already truncated to 3 dp, so the resolved place is "
        d += "accurate to city/neighbourhood, which is all that is wanted."

        return ProbeItem(
            "location.geocode", "CLGeocoder reverse geocode",
            status,
            value: geoValue,
            detail: d,
            extra: extra)
    }

    // MARK: - Summary

    private func buildSummary(finalStatus: CLAuthorizationStatus,
                              accuracy: CLAccuracyAuthorization,
                              servicesEnabled: Bool,
                              gotFix: Bool,
                              hasLocationMode: Bool,
                              maxRegionDistance: CLLocationDistance) -> String {
        var s = "Authorization ended at \(LocationProbeFmt.auth(finalStatus)) with "
        s += "\(LocationProbeFmt.accuracy(accuracy)); system Location Services "
        s += servicesEnabled ? "ON" : "OFF"
        s += gotFix ? "; live fix obtained. " : "; live fix NOT obtained. "
        s += "All coordinates in this section are truncated to 3 decimal places (≈110 m) "
        s += "before they are written anywhere — never a precise home coordinate.\n\n"

        s += "RELAUNCH MATRIX — the single most important architectural fact for a "
        s += "background collector, verified against Apple's own documentation:\n"
        s += "• RELAUNCH a terminated app: startMonitoringVisits() (\"the system relaunches "
        s += "your app when new visit events are ready to be delivered\"), "
        s += "startMonitoringSignificantLocationChanges() (\"automatically relaunches the app "
        s += "into the background\", flagged by UIApplication.LaunchOptionsKey.location), "
        s += "region monitoring via startMonitoring(for:), and CLMonitor conditions — whose "
        s += "conditions are persistent by design.\n"
        s += "• DO NOT relaunch, and stop silently on termination: startUpdatingLocation(), "
        s += "CLLocationUpdate.liveUpdates(), startUpdatingHeading(), and beacon ranging. "
        s += "A collector built on these dies the moment the app is killed and gives no "
        s += "signal that it did.\n"
        s += "• Two conditions defeat ALL of the above: if the user turns off Background App "
        s += "Refresh (globally or for this app) the system relaunches for no location event "
        s += "at all; and a user force-quit from the app switcher suppresses relaunch until "
        s += "the app is next opened manually, which is different from a system-initiated "
        s += "termination. Neither is detectable from inside CoreLocation, so a collector must "
        s += "cross-check UIApplication.backgroundRefreshStatus and heartbeat its own liveness.\n\n"

        s += "Region monitoring is capped at 20 regions PER APP (Apple: \"An app can register "
        s += "up to 20 regions at a time\"), shared across every CLLocationManager instance and "
        s += "persistent across launches; maximumRegionMonitoringDistance on this device is "
        s += "\(LocationProbeFmt.m(maxRegionDistance)). CLMonitor carries the same 20-condition "
        s += "ceiling. Any place-based collector therefore has to swap geofences dynamically.\n\n"

        s += "MEASURED NEGATIVE on history: CoreLocation has no CLVisit (or location) history "
        s += "API of any kind — no query, no date range, no backfill. The framework is strictly "
        s += "forward-only, so the effective backfill window is ZERO and a collector only ever "
        s += "sees events that occur while it is registered. The only historical visit store on "
        s += "iOS is SensorKit's SRSensorVisits, which requires an Apple-granted research "
        s += "entitlement.\n\n"

        s += "allowsBackgroundLocationUpdates was "
        if hasLocationMode {
            s += "set to true and read back successfully — this build declares the \"location\" "
            s += "UIBackgroundMode, which Apple documents as mandatory (\"Setting the value to "
            s += "true but omitting the UIBackgroundModes key … is a fatal error that "
            s += "terminates the app\"). The Info.plist was read at runtime FIRST, because that "
            s += "failure is an uncatchable trap, not a throwable error. It is NOT required "
            s += "for visits, significant-change or region monitoring — only for continuous "
            s += "updates — and it was restored to false so the probe leaves no blue indicator."
        } else {
            s += "deliberately NOT set: this build does not declare the \"location\" "
            s += "UIBackgroundMode, and setting the flag without it terminates the app."
        }

        s += "\n\nDeliberately omitted: requestTemporaryFullAccuracyAuthorization("
        s += "withPurposeKey:), because it requires an NSLocationTemporaryUsageDescription"
        s += "Dictionary entry that this build's Info.plist does not define — calling it "
        s += "without one is a no-op that would have reported a false negative. "
        s += "startMonitoringSignificantLocationChanges() was reported for availability but "
        s += "not started, because starting it leaves a persistent background service running "
        s += "after the report finishes. Beacon RANGING was not exercised because it needs a "
        s += "physical iBeacon in range. Deprecated deferred-updates batching "
        s += "(allowDeferredLocationUpdates) was probed for availability only — Apple's own "
        s += "deprecation note is \"You can remove calls to this method\"."
        return s
    }
}
