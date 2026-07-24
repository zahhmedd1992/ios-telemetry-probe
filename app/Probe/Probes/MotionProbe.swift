import Foundation
import CoreMotion
import ObjectiveC

// MARK: - MotionProbe
//
// Ground-truth probe of the whole CoreMotion surface on one physical iPhone.
//
// Design notes worth knowing before editing:
//
// 1. Every CoreMotion permission funnels through ONE "Motion & Fitness" prompt.
//    There is no explicit `requestAuthorization` for pedometer/activity — the
//    prompt is raised as a side effect of the first data query. So this probe
//    fires exactly one cheap bootstrap query up front, waits for the user, and
//    then reports the resulting authorization status as its own item, kept
//    strictly separate from whether any data actually came back. Those two
//    differ constantly and the difference is the finding.
//
// 2. If `NSMotionUsageDescription` is missing from Info.plist, iOS *kills the
//    process* on the first motion query — an uncatchable termination that would
//    destroy the entire report, not just this section. So the key is checked
//    first and every prompting API is skipped if it is absent. Raw
//    CMMotionManager sensors are not permission-gated and still run.
//
// 3. This probe does NOT use `withProbeTimeout` for callback APIs. That helper
//    is built on `withTaskGroup`, which awaits its remaining children when the
//    scope exits; `withCheckedContinuation` is not cancellation-aware, so a
//    continuation that never gets resumed would park the group forever — the
//    exact failure it is supposed to prevent. `MotionProbeUtil.awaitCallback`
//    resumes from a dispatch timer instead, with a claim-once guard, so every
//    path terminates whether the framework calls back or not.
//
// 4. Two classes are inspected via the Objective-C runtime rather than
//    referenced at compile time: `CMFallDetectionManager` (declared watchOS-only
//    — a compile-time reference does not build for iOS) and
//    `CMBatchedSensorManager` (headers annotate watchOS 10 only; the iOS row in
//    Apple's docs is a generator artifact). `NSClassFromString` is public API,
//    answers the literal question "does the class exist on iPhone", and cannot
//    break the build for the other ten probes in this module.
//
// Total worst-case wall time is budgeted at ~120s against the runner's 180s cap.

struct MotionProbe: TelemetryProbe {
    let key = "motion"
    let title = "CoreMotion"

    // Deadlines (seconds). Sum of worst cases must stay under the runner's cap.
    private static let bootstrapTimeout: Double = 45   // includes human tap time
    private static let queryTimeout: Double = 12
    private static let sliceTimeout: Double = 3
    private static let liveTimeout: Double = 3
    private static let headphoneTimeout: Double = 3.5
    private static let recorderTimeout: Double = 10

    func run() async -> ProbeSection {
        var items: [ProbeItem] = []
        var notes: [String] = []

        let now = Date()

        // ------------------------------------------------------------------
        // 0. Info.plist precondition — a missing usage string is an OS kill.
        // ------------------------------------------------------------------
        let usage = Bundle.main.object(forInfoDictionaryKey: "NSMotionUsageDescription") as? String
        let motionUsageOK = (usage?.isEmpty == false)

        items.append(ProbeItem(
            "motion.plist.usageDescription",
            "Info.plist NSMotionUsageDescription",
            motionUsageOK ? .ok : .error,
            value: motionUsageOK ? "present" : "MISSING",
            detail: motionUsageOK
                ? "Required for every permission-gated CoreMotion API. Present, so the Motion & Fitness prompt can be raised."
                : "ABSENT. iOS terminates the process on the first pedometer/activity/altimeter/headphone/recorder call when this key is missing — that would kill the whole report, not just this section. All prompting APIs were therefore SKIPPED. Raw CMMotionManager sensors are not permission-gated and still ran. Add NSMotionUsageDescription to Info.plist and re-run.",
            extra: usage.map { ["text": $0] }
        ))
        if !motionUsageOK {
            notes.append("NSMotionUsageDescription missing — all permission-gated CoreMotion APIs skipped to avoid an uncatchable process kill.")
        }

        if ProbeEnv.isSimulator {
            notes.append("Running in the Simulator: CoreMotion hardware is absent and every availability flag below is meaningless. Build to a real device.")
        }

        // ------------------------------------------------------------------
        // 1. Permission bootstrap — one prompt, raised deliberately and early.
        // ------------------------------------------------------------------
        let activityAvailable = CMMotionActivityManager.isActivityAvailable()
        let pedometer = CMPedometer()
        let activityManager = CMMotionActivityManager()

        let authBefore = CMMotionActivityManager.authorizationStatus()
        var bootstrapPath = "skipped"
        var bootstrapDetail: String?

        if motionUsageOK {
            if activityAvailable {
                bootstrapPath = "CMMotionActivityManager.queryActivityStarting (60s window)"
                let r = await queryActivity(activityManager,
                                            from: now.addingTimeInterval(-60),
                                            to: now,
                                            timeout: MotionProbe.bootstrapTimeout)
                bootstrapDetail = r.timedOut
                    ? "bootstrap query did not return within \(Int(MotionProbe.bootstrapTimeout))s"
                    : (r.error ?? "returned \(r.segments.count) segment(s)")
            } else {
                // Activity unavailable means the activity query never prompts, and
                // the pedometer would raise the sheet later, mid-probe, after a
                // deadline may already have burned. Prompt here instead.
                bootstrapPath = "CMPedometer.queryPedometerData (60s window) — activity unavailable"
                let r = await queryPedometer(pedometer,
                                             from: now.addingTimeInterval(-60),
                                             to: now,
                                             timeout: MotionProbe.bootstrapTimeout)
                bootstrapDetail = r.timedOut
                    ? "bootstrap query did not return within \(Int(MotionProbe.bootstrapTimeout))s"
                    : (r.error ?? "returned data")
            }
        }

        let authAfter = CMMotionActivityManager.authorizationStatus()
        let pedAuth = CMPedometer.authorizationStatus()
        let altAuth = CMAltimeter.authorizationStatus()
        let recAuth = CMSensorRecorder.authorizationStatus()
        let hpAuth = CMHeadphoneMotionManager.authorizationStatus()
        let granted = (authAfter == .authorized)

        var authExtra: [String: String] = [
            "statusBeforeBootstrap": MotionProbeUtil.authName(authBefore),
            "statusAfterBootstrap": MotionProbeUtil.authName(authAfter),
            "bootstrapPath": bootstrapPath,
            "CMMotionActivityManager.authorizationStatus": MotionProbeUtil.authName(authAfter),
            "CMPedometer.authorizationStatus": MotionProbeUtil.authName(pedAuth),
            "CMAltimeter.authorizationStatus": MotionProbeUtil.authName(altAuth),
            "CMSensorRecorder.authorizationStatus": MotionProbeUtil.authName(recAuth),
            "CMHeadphoneMotionManager.authorizationStatus": MotionProbeUtil.authName(hpAuth),
            "CMWaterSubmersionManager.authorizationStatus": MotionProbeUtil.authName(CMWaterSubmersionManager.authorizationStatus)
        ]
        if let bootstrapDetail { authExtra["bootstrapResult"] = bootstrapDetail }

        var authNarrative = "All six CoreMotion permission surfaces read back the same underlying Motion & Fitness grant; they are listed separately in `extra` so a divergence would be visible rather than assumed away. This status is reported independently of whether any data came back — the two differ constantly."
        if authAfter == .notDetermined && motionUsageOK {
            authNarrative += " STILL notDetermined after the bootstrap: the user had not answered the sheet when the deadline elapsed. Every data item below may therefore under-report; this is a race, not a denial."
            notes.append("Motion & Fitness prompt was not answered before the bootstrap deadline — data items may under-report.")
        }
        if !motionUsageOK {
            authNarrative = "Bootstrap skipped because NSMotionUsageDescription is absent. Status shown is whatever iOS already had on file."
        }

        items.append(ProbeItem(
            "motion.authorization",
            "Motion & Fitness authorization (single prompt for all of CoreMotion)",
            motionUsageOK ? MotionProbeUtil.authStatus(authAfter) : .error,
            value: MotionProbeUtil.authName(authAfter),
            detail: authNarrative,
            extra: authExtra
        ))

        // ------------------------------------------------------------------
        // 2. CMPedometer — availability flags
        // ------------------------------------------------------------------
        let pedFlags: [(String, Bool)] = [
            ("isStepCountingAvailable", CMPedometer.isStepCountingAvailable()),
            ("isDistanceAvailable", CMPedometer.isDistanceAvailable()),
            ("isFloorCountingAvailable", CMPedometer.isFloorCountingAvailable()),
            ("isPaceAvailable", CMPedometer.isPaceAvailable()),
            ("isCadenceAvailable", CMPedometer.isCadenceAvailable()),
            ("isPedometerEventTrackingAvailable", CMPedometer.isPedometerEventTrackingAvailable())
        ]
        let pedYes = pedFlags.filter { $0.1 }.count
        var pedFlagExtra: [String: String] = [:]
        for f in pedFlags { pedFlagExtra[f.0] = f.1 ? "true" : "false" }
        pedFlagExtra["availableCount"] = "\(pedYes)"
        pedFlagExtra["totalFlags"] = "\(pedFlags.count)"

        items.append(ProbeItem(
            "motion.pedometer.availability",
            "CMPedometer capability flags",
            pedYes == pedFlags.count ? .ok : (pedYes == 0 ? .unavailable : .partial),
            value: "\(pedYes) of \(pedFlags.count) available",
            detail: "Hardware/OS capability only — independent of authorization. Unavailable flags on an iPhone usually mean the M-series motion coprocessor does not expose that derivation (floor counting needs the barometer).",
            extra: pedFlagExtra
        ))

        // ------------------------------------------------------------------
        // 3. CMPedometer — last 24h
        // ------------------------------------------------------------------
        if motionUsageOK {
            let r24 = await queryPedometer(pedometer,
                                           from: now.addingTimeInterval(-86_400),
                                           to: now,
                                           timeout: MotionProbe.queryTimeout)
            items.append(pedometerItem(
                key: "motion.pedometer.last24h",
                label: "CMPedometer — last 24 hours",
                reading: r24,
                requestedFrom: now.addingTimeInterval(-86_400),
                requestedTo: now,
                granted: granted,
                extraDetail: "Live rolling 24h window. Pace is reported by Apple in seconds/meter; a min/km conversion is included for legibility."
            ))

            // --------------------------------------------------------------
            // 4. CMPedometer — 30-day query. THE headline backfill measurement.
            //    If iOS clamps the returned startDate to the oldest retained
            //    sample, that clamp point IS the real retention boundary,
            //    measured in a single call. If it echoes the request back
            //    verbatim, the day-slice walk below arbitrates instead.
            // --------------------------------------------------------------
            let from30 = now.addingTimeInterval(-30 * 86_400)
            let r30 = await queryPedometer(pedometer, from: from30, to: now, timeout: MotionProbe.queryTimeout)

            var clampExtra: [String: String] = [
                "requestedFrom": ProbeEnv.iso.string(from: from30),
                "requestedTo": ProbeEnv.iso.string(from: now),
                "requestedSpanDays": "30",
                "documentedRetentionDays": "7"
            ]
            var clampStatus: ProbeStatus = .empty
            var clampValue = "no data returned"
            var clampDetail = "Apple documents CMPedometer as retaining up to 7 days of history. This item measures the real number by asking for 30 and comparing what came back."

            if let rs = r30.start, let re = r30.end {
                let clampedDays = now.timeIntervalSince(rs) / 86_400
                let requestedDays = now.timeIntervalSince(from30) / 86_400
                let didClamp = rs.timeIntervalSince(from30) > 3_600  // >1h later than asked
                clampExtra["returnedStartDate"] = ProbeEnv.iso.string(from: rs)
                clampExtra["returnedEndDate"] = ProbeEnv.iso.string(from: re)
                clampExtra["returnedSpanDays"] = String(format: "%.3f", clampedDays)
                clampExtra["clamped"] = didClamp ? "true" : "false"
                clampExtra["clampShortfallDays"] = String(format: "%.3f", requestedDays - clampedDays)
                if let s = r30.steps { clampExtra["stepsOverReturnedSpan"] = "\(s)" }
                if let d = r30.distanceM { clampExtra["distanceMetersOverReturnedSpan"] = String(format: "%.1f", d) }
                clampStatus = (r30.steps ?? 0) > 0 ? .ok : .empty
                clampValue = didClamp
                    ? String(format: "clamped to %.2f days (asked 30)", clampedDays)
                    : String(format: "returned full %.2f days (no clamp)", clampedDays)
                clampDetail += didClamp
                    ? " MEASURED: iOS silently moved startDate forward to \(ProbeEnv.iso.string(from: rs)) — \(ProbeEnv.age(rs) ?? "?"). That is this device's actual pedometer retention boundary."
                    : " MEASURED: iOS echoed the requested startDate back unchanged, so the clamp is not observable this way; use motion.pedometer.retentionWalk below, which probes single-day slices and is not subject to echo."
            } else if let e = r30.error {
                clampStatus = granted ? .error : .denied
                clampValue = "query failed"
                clampDetail += " Error: \(e)"
                clampExtra["error"] = e
            } else if r30.timedOut {
                clampStatus = .error
                clampValue = "timed out"
                clampDetail += " The query did not return within \(Int(MotionProbe.queryTimeout))s."
            }

            items.append(ProbeItem(
                "motion.pedometer.retention30d",
                "CMPedometer — 30-day request vs. what iOS actually returned",
                granted ? clampStatus : (authAfter == .notDetermined ? .notDetermined : .denied),
                value: clampValue,
                detail: clampDetail,
                extra: clampExtra
            ))

            // --------------------------------------------------------------
            // 5. Day-slice retention walk. Single-day windows, not cumulative:
            //    a cumulative query would just clamp and hide the boundary.
            //    Caveat recorded below — a zero-step slice can also mean a day
            //    the user simply did not move, so the ERROR column is the
            //    stronger signal.
            // --------------------------------------------------------------
            let offsets = [1, 3, 7, 10, 14, 21, 30]
            var walkExtra: [String: String] = [:]
            var oldestNonZero: Int?
            var oldestAnyData: Int?
            var firstErrorAt: Int?

            for d in offsets {
                let sliceEnd = now.addingTimeInterval(-Double(d - 1) * 86_400)
                let sliceStart = now.addingTimeInterval(-Double(d) * 86_400)
                let r = await queryPedometer(pedometer, from: sliceStart, to: sliceEnd, timeout: MotionProbe.sliceTimeout)
                let tag = "dayMinus\(d)"
                walkExtra["\(tag).window"] = "\(ProbeEnv.iso.string(from: sliceStart)) .. \(ProbeEnv.iso.string(from: sliceEnd))"
                if let e = r.error {
                    walkExtra["\(tag).error"] = e
                    if firstErrorAt == nil { firstErrorAt = d }
                } else if r.timedOut {
                    walkExtra["\(tag).error"] = "timed out after \(Int(MotionProbe.sliceTimeout))s"
                } else if r.ok {
                    let s = r.steps ?? 0
                    walkExtra["\(tag).steps"] = "\(s)"
                    if let dist = r.distanceM { walkExtra["\(tag).distanceMeters"] = String(format: "%.1f", dist) }
                    if let up = r.floorsUp { walkExtra["\(tag).floorsAscended"] = "\(up)" }
                    if let rs = r.start { walkExtra["\(tag).returnedStart"] = ProbeEnv.iso.string(from: rs) }
                    if oldestAnyData == nil || d > (oldestAnyData ?? 0) { oldestAnyData = d }
                    if s > 0 { oldestNonZero = max(oldestNonZero ?? 0, d) }
                } else {
                    walkExtra["\(tag).steps"] = "no data object"
                }
            }
            walkExtra["probedOffsetsDays"] = offsets.map(String.init).joined(separator: ",")
            if let o = oldestNonZero { walkExtra["oldestSliceWithNonZeroSteps"] = "\(o)" }
            if let o = oldestAnyData { walkExtra["oldestSliceReturningData"] = "\(o)" }
            if let f = firstErrorAt { walkExtra["firstSliceReturningError"] = "\(f)" }

            let walkValue: String = {
                if let o = oldestNonZero { return "non-zero steps as far back as day −\(o)" }
                if let o = oldestAnyData { return "data objects to day −\(o), all zero steps" }
                return "no slice returned data"
            }()

            items.append(ProbeItem(
                "motion.pedometer.retentionWalk",
                "CMPedometer — measured history window (day-slice walk)",
                granted ? (oldestNonZero != nil ? .ok : .empty)
                        : (authAfter == .notDetermined ? .notDetermined : .denied),
                value: walkValue,
                detail: "Seven independent single-day windows at −1, −3, −7, −10, −14, −21 and −30 days. Cumulative queries clamp and hide the boundary; single-day slices do not. CAVEAT: a zero-step slice can mean 'outside retention' OR 'a day he did not walk', so the per-slice error column in `extra` is the harder signal — the first slice that returns an error is the retention wall. Apple documents 7 days.",
                extra: walkExtra
            ))

            // --------------------------------------------------------------
            // 6. CMPedometerEvent pause/resume stream
            // --------------------------------------------------------------
            if CMPedometer.isPedometerEventTrackingAvailable() {
                let ev = await MotionProbeUtil.awaitCallback(2.5, fallback: MotionProbeEventResult(timedOut: true)) { finish in
                    pedometer.startEventUpdates { event, error in
                        var r = MotionProbeEventResult()
                        if let error { r.error = MotionProbeUtil.describe(error) }
                        if let event {
                            r.received = true
                            r.date = event.date
                            r.type = (event.type == .pause) ? "pause" : "resume"
                        }
                        finish(r)
                    }
                }
                pedometer.stopEventUpdates()

                var evExtra: [String: String] = ["isPedometerEventTrackingAvailable": "true",
                                                 "listenWindowSeconds": "2.5"]
                if let d = ev.date { evExtra["eventDate"] = ProbeEnv.iso.string(from: d) }
                if let t = ev.type { evExtra["eventType"] = t }
                if let e = ev.error { evExtra["error"] = e }

                items.append(ProbeItem(
                    "motion.pedometer.events",
                    "CMPedometerEvent — walking pause/resume tracking",
                    ev.error != nil ? (granted ? .error : .denied) : (ev.received ? .ok : .empty),
                    value: ev.received ? "\(ev.type ?? "event") at \(ProbeEnv.stamp(ev.date) ?? "?")"
                                       : (ev.error != nil ? "stream error" : "stream started, no event in 2.5s"),
                    detail: "Pause/resume events fire only at real walking transitions, so silence over a 2.5s listen is the expected result and means the stream is live, not broken. There is no historical query for these — they are live-only, which is the collection constraint worth recording.",
                    extra: evExtra
                ))
            } else {
                items.append(ProbeItem(
                    "motion.pedometer.events",
                    "CMPedometerEvent — walking pause/resume tracking",
                    .unavailable,
                    value: "not available",
                    detail: "CMPedometer.isPedometerEventTrackingAvailable() returned false on this hardware.",
                    extra: ["isPedometerEventTrackingAvailable": "false"]
                ))
            }
        } else {
            for (k, l) in [("motion.pedometer.last24h", "CMPedometer — last 24 hours"),
                           ("motion.pedometer.retention30d", "CMPedometer — 30-day request vs. returned"),
                           ("motion.pedometer.retentionWalk", "CMPedometer — measured history window"),
                           ("motion.pedometer.events", "CMPedometerEvent — pause/resume tracking")] {
                items.append(ProbeItem(k, l, .error, value: "skipped",
                                       detail: "Skipped: NSMotionUsageDescription absent, and calling this would terminate the process."))
            }
        }

        // ------------------------------------------------------------------
        // 7. CMMotionActivityManager
        // ------------------------------------------------------------------
        items.append(ProbeItem(
            "motion.activity.availability",
            "CMMotionActivityManager.isActivityAvailable()",
            activityAvailable ? .ok : .unavailable,
            value: activityAvailable ? "true" : "false",
            detail: "Whether the motion coprocessor classifies activity at all. Distinct from authorization, reported at motion.authorization.",
            extra: ["isActivityAvailable": activityAvailable ? "true" : "false",
                    "authorizationStatus": MotionProbeUtil.authName(authAfter)]
        ))

        if motionUsageOK && activityAvailable {
            let from30 = now.addingTimeInterval(-30 * 86_400)
            let act = await queryActivity(activityManager, from: from30, to: now, timeout: 25)
            items.append(contentsOf: activityItems(act,
                                                   requestedFrom: from30,
                                                   requestedTo: now,
                                                   granted: granted,
                                                   auth: authAfter))
        } else {
            let why = !motionUsageOK
                ? "Skipped: NSMotionUsageDescription absent."
                : "Skipped: isActivityAvailable() is false on this device."
            for (k, l) in [("motion.activity.last30d", "CMMotionActivityManager — 30-day segment history"),
                           ("motion.activity.backfill", "CMMotionActivityManager — measured backfill window"),
                           ("motion.activity.confidence", "CMMotionActivityManager — confidence distribution")] {
                items.append(ProbeItem(k, l, activityAvailable ? .error : .unavailable, value: "skipped", detail: why))
            }
        }

        // ------------------------------------------------------------------
        // 8. CMAltimeter
        // ------------------------------------------------------------------
        let relAvail = CMAltimeter.isRelativeAltitudeAvailable()
        let absAvail = CMAltimeter.isAbsoluteAltitudeAvailable()

        items.append(ProbeItem(
            "motion.altimeter.availability",
            "CMAltimeter capability flags",
            relAvail ? (absAvail ? .ok : .partial) : .unavailable,
            value: "relative=\(MotionProbeUtil.flag(relAvail)), absolute=\(MotionProbeUtil.flag(absAvail))",
            detail: "Relative altitude is barometer-derived and needs no location fix. Absolute altitude (iOS 15+) fuses barometer with GPS and requires a location fix to converge, so it can be 'available' yet never deliver a sample indoors.",
            extra: ["isRelativeAltitudeAvailable": relAvail ? "true" : "false",
                    "isAbsoluteAltitudeAvailable": absAvail ? "true" : "false",
                    "authorizationStatus": MotionProbeUtil.authName(altAuth)]
        ))

        if motionUsageOK && relAvail {
            let altimeter = CMAltimeter()
            let sample = await MotionProbeUtil.awaitCallback(MotionProbe.liveTimeout,
                                                            fallback: MotionProbeAltitudeSample(timedOut: true)) { finish in
                altimeter.startRelativeAltitudeUpdates(to: MotionProbeUtil.queue("motion.altimeter.rel")) { data, error in
                    var r = MotionProbeAltitudeSample()
                    if let error { r.error = MotionProbeUtil.describe(error) }
                    if let data {
                        r.received = true
                        r.relativeAltitudeM = data.relativeAltitude.doubleValue
                        r.pressureKPa = data.pressure.doubleValue
                        r.timestamp = data.timestamp
                    }
                    finish(r)
                }
            }
            altimeter.stopRelativeAltitudeUpdates()

            var altExtra: [String: String] = ["sampleWindowSeconds": "\(MotionProbe.liveTimeout)"]
            if let p = sample.pressureKPa {
                altExtra["pressureKPa"] = String(format: "%.4f", p)
                altExtra["pressureHPa"] = String(format: "%.2f", p * 10.0)
                altExtra["pressureInHg"] = String(format: "%.3f", p * 0.2952998)
                // ISA barometric approximation, purely for sanity-checking the reading.
                let est = 44_330.0 * (1.0 - pow(p / 101.325, 0.1902949))
                altExtra["isaEstimatedAltitudeMeters"] = String(format: "%.1f", est)
            }
            if let r = sample.relativeAltitudeM { altExtra["relativeAltitudeMeters"] = String(format: "%.3f", r) }
            if let t = sample.timestamp { altExtra["cmLogItemTimestampSinceBoot"] = String(format: "%.3f", t) }
            if let e = sample.error { altExtra["error"] = e }

            items.append(ProbeItem(
                "motion.altimeter.relative",
                "CMAltimeter — live relative altitude / barometric pressure",
                sample.received ? .ok : (sample.error != nil ? (granted ? .error : .denied) : .empty),
                value: sample.pressureKPa.map { String(format: "%.3f kPa (%.1f hPa)", $0, $0 * 10.0) }
                    ?? (sample.timedOut ? "no sample in \(MotionProbe.liveTimeout)s" : "no sample"),
                detail: "Relative altitude is always ~0 on the first sample — it is measured from the moment updates start, not from sea level. The pressure figure is the absolute, useful one: it is a raw barometric reading in kPa, sampled at roughly 1 Hz, and it is the highest-value continuous signal here (weather, indoor floor changes, and a surprisingly good building-level location fingerprint).",
                extra: altExtra
            ))

            if absAvail {
                let absSample = await MotionProbeUtil.awaitCallback(MotionProbe.liveTimeout,
                                                                   fallback: MotionProbeAbsoluteAltitudeSample(timedOut: true)) { finish in
                    altimeter.startAbsoluteAltitudeUpdates(to: MotionProbeUtil.queue("motion.altimeter.abs")) { data, error in
                        var r = MotionProbeAbsoluteAltitudeSample()
                        if let error { r.error = MotionProbeUtil.describe(error) }
                        if let data {
                            r.received = true
                            r.altitudeM = data.altitude
                            r.accuracy = data.accuracy
                            r.precision = data.precision
                            r.timestamp = data.timestamp
                        }
                        finish(r)
                    }
                }
                altimeter.stopAbsoluteAltitudeUpdates()

                var absExtra: [String: String] = ["sampleWindowSeconds": "\(MotionProbe.liveTimeout)"]
                if let a = absSample.altitudeM { absExtra["altitudeMeters"] = String(format: "%.2f", a) }
                if let a = absSample.accuracy { absExtra["accuracyMeters"] = String(format: "%.2f", a) }
                if let p = absSample.precision { absExtra["precisionMeters"] = String(format: "%.2f", p) }
                if let e = absSample.error { absExtra["error"] = e }

                items.append(ProbeItem(
                    "motion.altimeter.absolute",
                    "CMAltimeter — live absolute altitude (iOS 15+)",
                    absSample.received ? .ok : (absSample.error != nil ? .error : .empty),
                    value: absSample.altitudeM.map { String(format: "%.1f m MSL", $0) }
                        ?? "no sample in \(MotionProbe.liveTimeout)s",
                    detail: "Absolute altitude needs a converged GPS fix to calibrate the barometer against sea level. Indoors, or before Location has been granted and warmed up, this legitimately never fires — an empty result here is a location problem, not an altimeter problem.",
                    extra: absExtra
                ))
            } else {
                items.append(ProbeItem(
                    "motion.altimeter.absolute",
                    "CMAltimeter — live absolute altitude (iOS 15+)",
                    .unavailable,
                    value: "not available",
                    detail: "isAbsoluteAltitudeAvailable() returned false on this hardware."
                ))
            }
        } else {
            let why = !motionUsageOK ? "Skipped: NSMotionUsageDescription absent."
                                     : "Skipped: isRelativeAltitudeAvailable() is false."
            items.append(ProbeItem("motion.altimeter.relative", "CMAltimeter — live relative altitude / pressure",
                                   relAvail ? .error : .unavailable, value: "skipped", detail: why))
            items.append(ProbeItem("motion.altimeter.absolute", "CMAltimeter — live absolute altitude (iOS 15+)",
                                   absAvail ? .error : .unavailable, value: "skipped", detail: why))
        }

        // ------------------------------------------------------------------
        // 9. CMMotionManager — raw sensors. NOT permission-gated, so these run
        //    even without a usage string. All four streams are started on one
        //    manager and sampled in a single 0.7s window rather than four
        //    sequential ones.
        // ------------------------------------------------------------------
        items.append(contentsOf: await motionManagerItems())

        // ------------------------------------------------------------------
        // 10. CMHeadphoneMotionManager — AirPods worn/connected state
        // ------------------------------------------------------------------
        if motionUsageOK {
            items.append(await headphoneItem(auth: hpAuth))
        } else {
            items.append(ProbeItem("motion.headphone", "CMHeadphoneMotionManager — AirPods head motion",
                                   .error, value: "skipped",
                                   detail: "Skipped: NSMotionUsageDescription absent."))
        }

        // ------------------------------------------------------------------
        // 11. CMSensorRecorder — the 3-day raw accelerometer question
        // ------------------------------------------------------------------
        items.append(contentsOf: await sensorRecorderItems(now: now,
                                                           motionUsageOK: motionUsageOK,
                                                           auth: recAuth))

        // ------------------------------------------------------------------
        // 12. CMWaterSubmersionManager (iOS 16+)
        // ------------------------------------------------------------------
        let waterAvail = CMWaterSubmersionManager.waterSubmersionAvailable
        let waterAuth = CMWaterSubmersionManager.authorizationStatus
        items.append(ProbeItem(
            "motion.waterSubmersion",
            "CMWaterSubmersionManager (iOS 16+)",
            waterAvail ? .ok : .unavailable,
            value: waterAvail ? "available" : "not available",
            detail: "Depth and water-temperature sensing, shipped for Apple Watch Ultra. Unlike CMBatchedSensorManager and CMFallDetectionManager below, this class IS genuinely declared for iOS: every member (waterSubmersionAvailable, authorizationStatus, maximumDepth, the delegate protocol) reports iOS 16.0 with no unavailable marker and no Mac Catalyst row, which is the signature of a real API_AVAILABLE(ios(16.0)) annotation rather than a doc-generator fallback. So this is a real runtime read, not a documentation claim. IMPORTANT: a false here cannot be attributed at runtime — it is indistinguishable between 'this iPhone has no depth sensor' (overwhelmingly the likely cause) and 'the com.apple.developer.submerged-depth-and-pressure entitlement is missing'. Both collapse to the same Bool. Do not read this as a measured hardware verdict.",
            extra: ["waterSubmersionAvailable": waterAvail ? "true" : "false",
                    "authorizationStatus": MotionProbeUtil.authName(waterAuth),
                    "requiresEntitlement": "com.apple.developer.submerged-depth-and-pressure",
                    "attributable": "false"]
        ))

        // ------------------------------------------------------------------
        // 13. CMBatchedSensorManager — runtime reflection, not a compile-time ref
        // ------------------------------------------------------------------
        let batchedExists = MotionProbeUtil.classExists("CMBatchedSensorManager")
        var batchedExtra: [String: String] = ["classExistsAtRuntime": batchedExists ? "true" : "false"]
        for sel in ["isAccelerometerSupported", "isDeviceMotionSupported", "authorizationStatus"] {
            batchedExtra["classMethod.\(sel)"] = MotionProbeUtil.hasClassMethod("CMBatchedSensorManager", sel) ? "present" : "absent"
        }
        batchedExtra["documentedPlatform"] = "watchOS 10.0+"
        batchedExtra["inspectionMethod"] = "NSClassFromString + class_getClassMethod (public ObjC runtime)"

        items.append(ProbeItem(
            "motion.batchedSensor",
            "CMBatchedSensorManager (high-rate batched sensors)",
            batchedExists ? .partial : .unavailable,
            value: batchedExists ? "class present in iOS CoreMotion" : "class absent on iPhone",
            detail: "Apple's headers annotate this watchOS 10+ only (the iOS row on developer.apple.com is a doc-generator artifact), and it additionally requires an active HealthKit workout session to emit anything. It is inspected here through the Objective-C runtime rather than referenced at compile time — a direct reference risks failing to build for iOS, which would break every probe in this module. Class presence alone does not imply the sensors are supported; the per-selector results in `extra` show exactly how much of the API surface iOS actually ships.",
            extra: batchedExtra
        ))

        // ------------------------------------------------------------------
        // 14. CMFallDetectionManager — watchOS-only, verified at runtime
        // ------------------------------------------------------------------
        let fallExists = MotionProbeUtil.classExists("CMFallDetectionManager")
        var fallExtra: [String: String] = ["classExistsAtRuntime": fallExists ? "true" : "false",
                                           "documentedPlatform": "watchOS 7.2+ only (no iOS availability row)",
                                           "inspectionMethod": "NSClassFromString + class_getClassMethod (public ObjC runtime)"]
        for sel in ["authorizationStatus", "isAvailable"] {
            fallExtra["classMethod.\(sel)"] = MotionProbeUtil.hasClassMethod("CMFallDetectionManager", sel) ? "present" : "absent"
        }

        items.append(ProbeItem(
            "motion.fallDetection",
            "CMFallDetectionManager (iOS 16+ per request; actually watchOS-only)",
            fallExists ? .partial : .unavailable,
            value: fallExists ? "class present, no iOS API surface" : "class absent on iPhone",
            detail: "CORRECTION TO THE BRIEF: this is not an iOS 16+ API. Apple's availability data lists watchOS 7.2 and no iOS row at all, so `CMFallDetectionManager` cannot be named in iOS-targeted Swift without failing to compile. Authorization therefore cannot be read on iPhone — there is no reachable authorizationStatus to call. Fall detection notifications on iPhone are delivered by the OS itself (Emergency SOS), not through an app-facing CoreMotion API. Checked via the ObjC runtime so the finding is measured rather than asserted.",
            extra: fallExtra
        ))

        // ------------------------------------------------------------------
        // Summary
        // ------------------------------------------------------------------
        var tally: [ProbeStatus: Int] = [:]
        for i in items { tally[i.status, default: 0] += 1 }
        let okCount = tally[.ok] ?? 0

        var summary = "\(items.count) CoreMotion checks; \(okCount) returned live data. "
        summary += "Motion & Fitness: \(MotionProbeUtil.authName(authAfter)) (one prompt gates pedometer, activity, altimeter, headphone motion and sensor recording alike — requested once during bootstrap, reported separately from data availability). "
        summary += "Retention windows are measured, not assumed: the pedometer is asked for 30 days and its returned startDate compared against the request, and activity history is walked back to find the genuinely oldest segment. "
        summary += "CMFallDetectionManager and CMBatchedSensorManager are inspected through the Objective-C runtime instead of being named in code — both are watchOS-only in Apple's headers and a compile-time reference would break the build for the whole module. "
        summary += "Deliberately omitted: CMMovementDisorderManager (Parkinson's research API, gated behind a special Apple entitlement no sideloaded profile can carry), CMHeadphoneMotionManagerDelegate connection callbacks (event-only — it reports transitions, never current state, so data arrival is the better connected/worn signal), and CMWaterSubmersionManagerDelegate (nothing to deliver without the depth-sensor entitlement)."
        if !notes.isEmpty { summary += " NOTES: " + notes.joined(separator: " ") }

        return section(summary, items)
    }

    // MARK: - Pedometer helpers

    private func queryPedometer(_ ped: CMPedometer,
                                from: Date,
                                to: Date,
                                timeout: Double) async -> MotionProbePedReading {
        var fallback = MotionProbePedReading()
        fallback.timedOut = true
        return await MotionProbeUtil.awaitCallback(timeout, fallback: fallback) { finish in
            ped.queryPedometerData(from: from, to: to) { data, error in
                var r = MotionProbePedReading()
                if let error { r.error = MotionProbeUtil.describe(error) }
                if let data {
                    r.ok = true
                    r.steps = data.numberOfSteps.intValue
                    r.distanceM = data.distance?.doubleValue
                    r.floorsUp = data.floorsAscended?.intValue
                    r.floorsDown = data.floorsDescended?.intValue
                    r.currentPace = data.currentPace?.doubleValue
                    r.averagePace = data.averageActivePace?.doubleValue
                    r.cadence = data.currentCadence?.doubleValue
                    r.start = data.startDate
                    r.end = data.endDate
                }
                finish(r)
            }
        }
    }

    private func pedometerItem(key itemKey: String,
                               label: String,
                               reading: MotionProbePedReading,
                               requestedFrom: Date,
                               requestedTo: Date,
                               granted: Bool,
                               extraDetail: String) -> ProbeItem {
        var extra: [String: String] = [
            "requestedFrom": ProbeEnv.iso.string(from: requestedFrom),
            "requestedTo": ProbeEnv.iso.string(from: requestedTo)
        ]
        var status: ProbeStatus = .empty
        var value = "no data"

        if let e = reading.error {
            extra["error"] = e
            status = granted ? .error : .denied
            value = "query failed"
        } else if reading.timedOut {
            status = .error
            value = "timed out"
            extra["error"] = "no callback within deadline"
        } else if reading.ok {
            if let s = reading.start { extra["returnedStartDate"] = ProbeEnv.iso.string(from: s) }
            if let e = reading.end { extra["returnedEndDate"] = ProbeEnv.iso.string(from: e) }
            if let s = reading.steps { extra["steps"] = "\(s)" }
            if let d = reading.distanceM {
                extra["distanceMeters"] = String(format: "%.1f", d)
                extra["distanceMiles"] = String(format: "%.3f", d / 1609.344)
            }
            if let f = reading.floorsUp { extra["floorsAscended"] = "\(f)" }
            if let f = reading.floorsDown { extra["floorsDescended"] = "\(f)" }
            if let p = reading.currentPace {
                extra["currentPaceSecPerMeter"] = String(format: "%.4f", p)
                if p > 0 { extra["currentPaceMinPerKm"] = String(format: "%.2f", p * 1000.0 / 60.0) }
            }
            if let p = reading.averagePace {
                extra["averageActivePaceSecPerMeter"] = String(format: "%.4f", p)
                if p > 0 { extra["averageActivePaceMinPerKm"] = String(format: "%.2f", p * 1000.0 / 60.0) }
            }
            if let c = reading.cadence {
                extra["currentCadenceStepsPerSecond"] = String(format: "%.3f", c)
                extra["currentCadenceStepsPerMinute"] = String(format: "%.1f", c * 60.0)
            }
            let steps = reading.steps ?? 0
            status = steps > 0 ? .ok : .empty
            var bits: [String] = ["\(ProbeEnv.int(steps)) steps"]
            if let d = reading.distanceM { bits.append(String(format: "%.2f km", d / 1000.0)) }
            if let f = reading.floorsUp { bits.append("\(f) floors up") }
            if let f = reading.floorsDown { bits.append("\(f) down") }
            value = bits.joined(separator: ", ")
        }

        return ProbeItem(itemKey, label, granted ? status : (status == .denied ? .denied : status),
                         value: value,
                         detail: extraDetail + " Pace and cadence are instantaneous fields and are nil unless the user is moving right now — nil here is normal, not a failure.",
                         extra: extra)
    }

    // MARK: - Activity helpers

    private func queryActivity(_ mgr: CMMotionActivityManager,
                               from: Date,
                               to: Date,
                               timeout: Double) async -> MotionProbeActivityResult {
        var fallback = MotionProbeActivityResult()
        fallback.timedOut = true
        return await MotionProbeUtil.awaitCallback(timeout, fallback: fallback) { finish in
            mgr.queryActivityStarting(from: from, to: to, to: MotionProbeUtil.queue("motion.activity")) { activities, error in
                var r = MotionProbeActivityResult()
                if let error { r.error = MotionProbeUtil.describe(error) }
                if let activities {
                    r.returned = true
                    r.segments = activities.map { a in
                        var classes: [String] = []
                        if a.stationary { classes.append("stationary") }
                        if a.walking { classes.append("walking") }
                        if a.running { classes.append("running") }
                        if a.automotive { classes.append("automotive") }
                        if a.cycling { classes.append("cycling") }
                        if a.unknown { classes.append("unknown") }
                        if classes.isEmpty { classes.append("none") }
                        return MotionProbeActivitySeg(start: a.startDate,
                                                      confidence: a.confidence.rawValue,
                                                      classes: classes)
                    }
                }
                finish(r)
            }
        }
    }

    private func activityItems(_ result: MotionProbeActivityResult,
                               requestedFrom: Date,
                               requestedTo: Date,
                               granted: Bool,
                               auth: CMAuthorizationStatus) -> [ProbeItem] {
        var out: [ProbeItem] = []
        let baseExtra: [String: String] = [
            "requestedFrom": ProbeEnv.iso.string(from: requestedFrom),
            "requestedTo": ProbeEnv.iso.string(from: requestedTo),
            "requestedSpanDays": "30"
        ]

        if result.error != nil || result.timedOut || !result.returned {
            let msg = result.error ?? (result.timedOut ? "no callback within deadline" : "handler returned nil array")
            var e = baseExtra
            e["error"] = msg
            let st: ProbeStatus = (auth == .notDetermined) ? .notDetermined : (granted ? .error : .denied)
            out.append(ProbeItem("motion.activity.last30d", "CMMotionActivityManager — 30-day segment history",
                                 st, value: "query failed", detail: msg, extra: e))
            out.append(ProbeItem("motion.activity.backfill", "CMMotionActivityManager — measured backfill window",
                                 st, value: "not measurable", detail: msg, extra: e))
            out.append(ProbeItem("motion.activity.confidence", "CMMotionActivityManager — confidence distribution",
                                 st, value: "not measurable", detail: msg, extra: e))
            return out
        }

        // Sort before differencing: unsorted input yields negative deltas that
        // silently poison per-class totals.
        let segs = result.segments.sorted { $0.start < $1.start }
        let n = segs.count

        var classCount: [String: Int] = [:]
        var classDuration: [String: Double] = [:]
        var confCount: [Int: Int] = [:]
        let horizon = min(requestedTo, Date())

        for (i, s) in segs.enumerated() {
            let nextStart: Date = (i + 1 < n) ? segs[i + 1].start : horizon
            let raw = nextStart.timeIntervalSince(s.start)
            let dur = raw > 0 ? raw : 0
            confCount[s.confidence, default: 0] += 1
            for c in s.classes {
                classCount[c, default: 0] += 1
                classDuration[c, default: 0] += dur
            }
        }

        let oldest = segs.first?.start
        let newest = segs.last?.start
        let spanSeconds: Double = {
            guard let o = oldest else { return 0 }
            return horizon.timeIntervalSince(o)
        }()

        // ---- Item: 30-day history ----
        var histExtra = baseExtra
        histExtra["segmentCount"] = "\(n)"
        histExtra["wallClockSpanCoveredDays"] = String(format: "%.3f", spanSeconds / 86_400)
        if n > 0 && spanSeconds > 0 {
            histExtra["segmentsPerDay"] = String(format: "%.1f", Double(n) / (spanSeconds / 86_400))
            histExtra["meanSegmentDurationSeconds"] = String(format: "%.1f", spanSeconds / Double(n))
        }
        for cls in ["stationary", "walking", "running", "automotive", "cycling", "unknown", "none"] {
            let c = classCount[cls] ?? 0
            let d = classDuration[cls] ?? 0
            histExtra["class.\(cls).count"] = "\(c)"
            histExtra["class.\(cls).totalSeconds"] = String(format: "%.0f", d)
            histExtra["class.\(cls).totalHours"] = String(format: "%.2f", d / 3600.0)
            if spanSeconds > 0 {
                histExtra["class.\(cls).percentOfSpan"] = String(format: "%.1f", 100.0 * d / spanSeconds)
            }
        }
        let summedClassSeconds = classDuration.values.reduce(0, +)
        histExtra["sumOfAllClassSeconds"] = String(format: "%.0f", summedClassSeconds)
        histExtra["classSecondsExceedSpan"] = summedClassSeconds > spanSeconds + 1 ? "true" : "false"

        let topClass = classDuration.max { $0.value < $1.value }
        out.append(ProbeItem(
            "motion.activity.last30d",
            "CMMotionActivityManager — 30-day segment history",
            n > 0 ? .ok : .empty,
            value: n > 0
                ? "\(ProbeEnv.int(n)) segments over \(String(format: "%.1f", spanSeconds / 86_400)) days"
                    + (topClass.map { ", mostly \($0.key)" } ?? "")
                : "no segments returned",
            detail: "One segment per detected activity transition. A single segment can carry MORE THAN ONE true class flag (walking + automotive on a bus, for example), so per-class durations legitimately sum to more than the wall-clock span — `classSecondsExceedSpan` in `extra` flags when that happened, and it is expected rather than a bug. Segment durations are derived from the gap to the next segment's startDate after sorting, with the final segment running to now. This is the single richest longitudinal signal in CoreMotion: a minute-resolution movement diary requiring no location permission at all.",
            extra: histExtra
        ))

        // ---- Item: measured backfill window (the headline) ----
        var backExtra = baseExtra
        backExtra["segmentCount"] = "\(n)"
        if let o = oldest {
            backExtra["oldestSegmentStartDate"] = ProbeEnv.iso.string(from: o)
            backExtra["oldestSegmentAge"] = ProbeEnv.age(o) ?? "?"
            // Measured against `horizon`, the same instant `spanSeconds` uses, so
            // the two never disagree by a stray sub-second when diffed.
            backExtra["measuredBackfillDays"] = String(format: "%.3f", horizon.timeIntervalSince(o) / 86_400)
            backExtra["requestExceededByDays"] = String(format: "%.3f",
                                                        30.0 - (horizon.timeIntervalSince(o) / 86_400))
        }
        if let nw = newest {
            backExtra["newestSegmentStartDate"] = ProbeEnv.iso.string(from: nw)
            backExtra["newestSegmentAge"] = ProbeEnv.age(nw) ?? "?"
        }

        out.append(ProbeItem(
            "motion.activity.backfill",
            "CMMotionActivityManager — measured backfill window",
            oldest != nil ? .ok : .empty,
            value: oldest.map { o in
                "\(String(format: "%.1f", horizon.timeIntervalSince(o) / 86_400)) days "
                + "(oldest segment \(ProbeEnv.iso.string(from: o)))"
            } ?? "no segments",
            detail: "THE measurement: 30 days were requested, and this is the timestamp of the oldest segment iOS actually handed back. Apple documents no retention figure for motion activity at all, so this number is the only way to know it. Treat it as a floor rather than a ceiling — if the device was off, in Airplane Mode, or newly restored, the wall may be data history rather than an OS retention limit. Re-run on a settled device to separate the two.",
            extra: backExtra
        ))

        // ---- Item: confidence distribution ----
        var confExtra = baseExtra
        let names = [0: "low", 1: "medium", 2: "high"]
        for (k, label) in names {
            let c = confCount[k] ?? 0
            confExtra["confidence.\(label).count"] = "\(c)"
            if n > 0 { confExtra["confidence.\(label).percent"] = String(format: "%.1f", 100.0 * Double(c) / Double(n)) }
        }
        for (k, v) in confCount where names[k] == nil {
            confExtra["confidence.raw\(k).count"] = "\(v)"
        }
        confExtra["segmentCount"] = "\(n)"

        let highPct = n > 0 ? 100.0 * Double(confCount[2] ?? 0) / Double(n) : 0
        out.append(ProbeItem(
            "motion.activity.confidence",
            "CMMotionActivityManager — confidence distribution",
            n > 0 ? .ok : .empty,
            value: n > 0 ? "\(String(format: "%.0f", highPct))% high — "
                            + "\(confCount[0] ?? 0) low / \(confCount[1] ?? 0) medium / \(confCount[2] ?? 0) high"
                         : "no segments",
            detail: "CMMotionActivityConfidence is a three-level enum (0 low, 1 medium, 2 high). Any downstream collector should filter on this: low-confidence segments are frequent and noisy, and treating them as fact is the usual way motion-activity analysis goes wrong.",
            extra: confExtra
        ))

        return out
    }

    // MARK: - CMMotionManager

    private func motionManagerItems() async -> [ProbeItem] {
        var out: [ProbeItem] = []
        let mm = CMMotionManager()

        let accelAvail = mm.isAccelerometerAvailable
        let gyroAvail = mm.isGyroAvailable
        let magAvail = mm.isMagnetometerAvailable
        let dmAvail = mm.isDeviceMotionAvailable

        let targetHz = 50.0
        let interval = 1.0 / targetHz
        mm.accelerometerUpdateInterval = interval
        mm.gyroUpdateInterval = interval
        mm.magnetometerUpdateInterval = interval
        mm.deviceMotionUpdateInterval = interval

        let accelSink = MotionProbeAccumulator()
        let gyroSink = MotionProbeAccumulator()
        let magSink = MotionProbeAccumulator()
        let dmSink = MotionProbeDeviceMotionSink()

        let q = MotionProbeUtil.queue("motion.raw")

        if accelAvail {
            mm.startAccelerometerUpdates(to: q) { data, error in
                if let error { accelSink.fail(MotionProbeUtil.describe(error) ?? "error"); return }
                guard let d = data else { return }
                accelSink.add(d.acceleration.x, d.acceleration.y, d.acceleration.z, d.timestamp)
            }
        }
        if gyroAvail {
            mm.startGyroUpdates(to: q) { data, error in
                if let error { gyroSink.fail(MotionProbeUtil.describe(error) ?? "error"); return }
                guard let d = data else { return }
                gyroSink.add(d.rotationRate.x, d.rotationRate.y, d.rotationRate.z, d.timestamp)
            }
        }
        if magAvail {
            mm.startMagnetometerUpdates(to: q) { data, error in
                if let error { magSink.fail(MotionProbeUtil.describe(error) ?? "error"); return }
                guard let d = data else { return }
                magSink.add(d.magneticField.x, d.magneticField.y, d.magneticField.z, d.timestamp)
            }
        }
        if dmAvail {
            mm.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: q) { data, error in
                if let error { dmSink.fail(MotionProbeUtil.describe(error) ?? "error"); return }
                guard let d = data else { return }
                dmSink.add(d)
            }
        }

        // One shared 0.7s window rather than four sequential ones.
        try? await Task.sleep(nanoseconds: 700_000_000)

        mm.stopAccelerometerUpdates()
        mm.stopGyroUpdates()
        mm.stopMagnetometerUpdates()
        mm.stopDeviceMotionUpdates()

        out.append(rawSensorItem(itemKey: "motion.mm.accelerometer",
                                 label: "CMMotionManager — accelerometer",
                                 available: accelAvail,
                                 stats: accelSink.stats(),
                                 unit: "g",
                                 targetHz: targetHz,
                                 note: "Raw, uncalibrated, gravity included — magnitude parks near 1.0 g at rest. Not gated by Motion & Fitness: raw inertial sensors need no permission at all, which makes them the one always-available CoreMotion stream."))

        out.append(rawSensorItem(itemKey: "motion.mm.gyroscope",
                                 label: "CMMotionManager — gyroscope",
                                 available: gyroAvail,
                                 stats: gyroSink.stats(),
                                 unit: "rad/s",
                                 targetHz: targetHz,
                                 note: "Raw rotation rate about the three body axes. Near-zero magnitude at rest; bias drift is visible as a small non-zero floor."))

        out.append(rawSensorItem(itemKey: "motion.mm.magnetometer",
                                 label: "CMMotionManager — magnetometer",
                                 available: magAvail,
                                 stats: magSink.stats(),
                                 unit: "µT",
                                 targetHz: targetHz,
                                 note: "Raw, uncalibrated magnetic field including hard/soft-iron offsets from the device itself. Earth's field is roughly 25–65 µT; a much larger magnitude means nearby metal or a magnetic case (MagSafe reads very hot)."))

        // Device motion
        let dmStats = dmSink.snapshot()
        var dmExtra: [String: String] = [
            "isDeviceMotionAvailable": dmAvail ? "true" : "false",
            "requestedHz": String(format: "%.1f", targetHz),
            "referenceFrameUsed": "xArbitraryZVertical",
            "sampleCount": "\(dmStats.count)"
        ]
        if dmStats.hz > 0 { dmExtra["achievedHz"] = String(format: "%.1f", dmStats.hz) }
        for (k, v) in dmStats.fields { dmExtra[k] = v }
        if let e = dmStats.error { dmExtra["error"] = e }

        out.append(ProbeItem(
            "motion.mm.deviceMotion",
            "CMMotionManager — device motion (fused)",
            !dmAvail ? .unavailable : (dmStats.count > 0 ? .ok : (dmStats.error != nil ? .error : .empty)),
            value: dmStats.count > 0
                ? "\(dmStats.count) samples at \(String(format: "%.1f", dmStats.hz)) Hz"
                : (dmAvail ? "no samples in 0.7s" : "not available"),
            detail: "The fused product: attitude (roll/pitch/yaw), gravity separated from user acceleration, calibrated magnetic field with an accuracy grade, and heading in degrees. Attitude and gravity together reveal exactly how the phone is being held — the richest per-sample posture signal on the device, and it needs no permission.",
            extra: dmExtra
        ))

        // Attitude reference frames
        let frames = CMMotionManager.availableAttitudeReferenceFrames()
        let frameTable: [(CMAttitudeReferenceFrame, String)] = [
            (.xArbitraryZVertical, "xArbitraryZVertical"),
            (.xArbitraryCorrectedZVertical, "xArbitraryCorrectedZVertical"),
            (.xMagneticNorthZVertical, "xMagneticNorthZVertical"),
            (.xTrueNorthZVertical, "xTrueNorthZVertical")
        ]
        var frameExtra: [String: String] = ["rawValue": "\(frames.rawValue)"]
        var availableFrames: [String] = []
        for (f, name) in frameTable {
            let has = frames.contains(f)
            frameExtra[name] = has ? "true" : "false"
            if has { availableFrames.append(name) }
        }
        frameExtra["availableCount"] = "\(availableFrames.count)"

        out.append(ProbeItem(
            "motion.mm.attitudeFrames",
            "CMMotionManager — available attitude reference frames",
            availableFrames.isEmpty ? .unavailable : (availableFrames.count == frameTable.count ? .ok : .partial),
            value: availableFrames.isEmpty ? "none" : availableFrames.joined(separator: ", "),
            detail: "xTrueNorthZVertical is the one that matters — it means device motion can be expressed in a true-north frame, which requires the magnetometer AND an active location fix for declination. Its presence here is a capability statement; actually using it will separately trip the Location permission.",
            extra: frameExtra
        ))

        return out
    }

    private func rawSensorItem(itemKey: String,
                               label: String,
                               available: Bool,
                               stats: MotionProbeSampleStats,
                               unit: String,
                               targetHz: Double,
                               note: String) -> ProbeItem {
        var extra: [String: String] = [
            "available": available ? "true" : "false",
            "requestedHz": String(format: "%.1f", targetHz),
            "sampleWindowSeconds": "0.7",
            "unit": unit,
            "sampleCount": "\(stats.count)"
        ]
        if stats.count > 1 {
            extra["achievedHz"] = String(format: "%.1f", stats.hz)
            extra["meanMagnitude"] = String(format: "%.4f", stats.meanMag)
            extra["minMagnitude"] = String(format: "%.4f", stats.minMag)
            extra["maxMagnitude"] = String(format: "%.4f", stats.maxMag)
        }
        if let x = stats.lastX { extra["lastSample.x"] = String(format: "%.4f", x) }
        if let y = stats.lastY { extra["lastSample.y"] = String(format: "%.4f", y) }
        if let z = stats.lastZ { extra["lastSample.z"] = String(format: "%.4f", z) }
        if let e = stats.error { extra["error"] = e }

        let status: ProbeStatus = !available ? .unavailable
            : (stats.error != nil ? .error : (stats.count > 0 ? .ok : .empty))
        let value: String = !available ? "not available"
            : (stats.count > 0
                ? "\(stats.count) samples, \(String(format: "%.1f", stats.hz)) Hz, mean |v| = \(String(format: "%.3f", stats.meanMag)) \(unit)"
                : "no samples in 0.7s")

        return ProbeItem(itemKey, label, status, value: value,
                         detail: note + " Achieved rate is measured from sample timestamps, not assumed from the requested interval — iOS routinely delivers a different rate than asked.",
                         extra: extra)
    }

    // MARK: - Headphone motion

    private func headphoneItem(auth: CMAuthorizationStatus) async -> ProbeItem {
        let hp = CMHeadphoneMotionManager()
        let avail = hp.isDeviceMotionAvailable

        var extra: [String: String] = [
            "isDeviceMotionAvailable": avail ? "true" : "false",
            "authorizationStatus": MotionProbeUtil.authName(auth),
            "waitSeconds": "\(MotionProbe.headphoneTimeout)"
        ]

        guard avail else {
            return ProbeItem("motion.headphone", "CMHeadphoneMotionManager — AirPods head motion",
                             .unavailable,
                             value: "device motion not available",
                             detail: "isDeviceMotionAvailable is false. On a supported iPhone this generally means no motion-capable headphones are currently connected — head tracking needs AirPods Pro, AirPods Max, AirPods (3rd gen) or later. It is a live connection state, not a fixed hardware capability, so re-running with AirPods in changes this answer.",
                             extra: extra)
        }

        let sample = await MotionProbeUtil.awaitCallback(MotionProbe.headphoneTimeout,
                                                        fallback: MotionProbeHeadphoneSample(timedOut: true)) { finish in
            hp.startDeviceMotionUpdates(to: MotionProbeUtil.queue("motion.headphone")) { dm, error in
                var r = MotionProbeHeadphoneSample()
                if let error { r.error = MotionProbeUtil.describe(error) }
                if let dm {
                    r.received = true
                    r.roll = dm.attitude.roll * 180.0 / .pi
                    r.pitch = dm.attitude.pitch * 180.0 / .pi
                    r.yaw = dm.attitude.yaw * 180.0 / .pi
                    r.gravityMag = (dm.gravity.x * dm.gravity.x
                                    + dm.gravity.y * dm.gravity.y
                                    + dm.gravity.z * dm.gravity.z).squareRoot()
                    r.userAccelMag = (dm.userAcceleration.x * dm.userAcceleration.x
                                      + dm.userAcceleration.y * dm.userAcceleration.y
                                      + dm.userAcceleration.z * dm.userAcceleration.z).squareRoot()
                    r.heading = dm.heading
                    r.timestamp = dm.timestamp
                }
                finish(r)
            }
        }
        hp.stopDeviceMotionUpdates()

        extra["isDeviceMotionActive"] = hp.isDeviceMotionActive ? "true" : "false"
        if let v = sample.roll { extra["attitude.rollDegrees"] = String(format: "%.2f", v) }
        if let v = sample.pitch { extra["attitude.pitchDegrees"] = String(format: "%.2f", v) }
        if let v = sample.yaw { extra["attitude.yawDegrees"] = String(format: "%.2f", v) }
        if let v = sample.gravityMag { extra["gravityMagnitudeG"] = String(format: "%.4f", v) }
        if let v = sample.userAccelMag { extra["userAccelerationMagnitudeG"] = String(format: "%.4f", v) }
        if let v = sample.heading { extra["headingDegrees"] = String(format: "%.2f", v) }
        if let v = sample.timestamp { extra["cmLogItemTimestampSinceBoot"] = String(format: "%.3f", v) }
        if let e = sample.error { extra["error"] = e }
        extra["airPodsWornInferred"] = sample.received ? "true" : "false"

        let status: ProbeStatus = sample.error != nil
            ? (auth == .authorized ? .error : .denied)
            : (sample.received ? .ok : .empty)

        return ProbeItem(
            "motion.headphone",
            "CMHeadphoneMotionManager — AirPods head motion",
            status,
            value: sample.received
                ? String(format: "head motion LIVE — yaw %.1f°, pitch %.1f°, roll %.1f°",
                         sample.yaw ?? 0, sample.pitch ?? 0, sample.roll ?? 0)
                : (sample.error != nil ? "error" : "available but no data in \(MotionProbe.headphoneTimeout)s"),
            detail: "This is the AirPods worn-and-connected detector. Data arriving proves the AirPods are connected, in-ear, and not already claimed by another app — CoreMotion hands head tracking to one client at a time, so an active Spatial Audio session elsewhere will silently starve this. `available but no data` therefore means connected-but-not-worn or taken by another app; it does not mean broken. Not measured here: CMHeadphoneMotionManagerDelegate's connect/disconnect callbacks, which are edge-triggered only and report transitions rather than current state — data arrival is the better instrument for a one-shot probe.",
            extra: extra
        )
    }

    // MARK: - CMSensorRecorder

    private func sensorRecorderItems(now: Date,
                                     motionUsageOK: Bool,
                                     auth: CMAuthorizationStatus) async -> [ProbeItem] {
        var out: [ProbeItem] = []

        let recAvail = CMSensorRecorder.isAccelerometerRecordingAvailable()
        let recAuthorized = CMSensorRecorder.isAuthorizedForRecording()

        out.append(ProbeItem(
            "motion.sensorRecorder.availability",
            "CMSensorRecorder — availability & authorization",
            recAvail ? (recAuthorized ? .ok : .denied) : .unavailable,
            value: "recordingAvailable=\(MotionProbeUtil.flag(recAvail)), authorizedForRecording=\(MotionProbeUtil.flag(recAuthorized))",
            detail: "VERIFIED against Apple's current availability data (July 2026): CMSensorRecorder is NOT deprecated and is still declared iOS 9.0+ / watchOS 2.0+ with no deprecation notice on the class or on recordAccelerometer(forDuration:) / accelerometerData(from:to:). It carries no special entitlement — it rides the same Motion & Fitness grant as everything else here. In practice, though, isAccelerometerRecordingAvailable() has returned false on iPhone for many years; the continuous background accelerometer log is an Apple Watch feature. The flags above are the measured answer for THIS device, and the two calls below attempt it regardless rather than trusting the prior.",
            extra: ["isAccelerometerRecordingAvailable": recAvail ? "true" : "false",
                    "isAuthorizedForRecording": recAuthorized ? "true" : "false",
                    "authorizationStatus": MotionProbeUtil.authName(auth),
                    "deprecated": "false",
                    "declaredSince": "iOS 9.0",
                    "entitlementRequired": "none",
                    "verifiedAgainst": "developer.apple.com availability data, July 2026"]
        ))

        guard motionUsageOK else {
            out.append(ProbeItem("motion.sensorRecorder.record", "CMSensorRecorder — recordAccelerometer(forDuration:)",
                                 .error, value: "skipped", detail: "Skipped: NSMotionUsageDescription absent."))
            out.append(ProbeItem("motion.sensorRecorder.query", "CMSensorRecorder — accelerometerData(from:to:) over 3 days",
                                 .error, value: "skipped", detail: "Skipped: NSMotionUsageDescription absent."))
            return out
        }

        let recorder = CMSensorRecorder()

        // recordAccelerometer is synchronous and can block; keep it off-thread.
        let recordDuration: TimeInterval = 60
        let recorded = await MotionProbeUtil.offThread(5.0, fallback: false) {
            recorder.recordAccelerometer(forDuration: recordDuration)
            return true
        }

        out.append(ProbeItem(
            "motion.sensorRecorder.record",
            "CMSensorRecorder — recordAccelerometer(forDuration:)",
            recAvail ? (recorded ? .ok : .error) : .unavailable,
            value: recAvail
                ? (recorded ? "accepted a \(Int(recordDuration))s recording request" : "call did not return in 5s")
                : "not attempted meaningfully — recording unavailable",
            detail: "The API returns Void and never reports failure, so 'accepted' means only that the call returned — it is not evidence that anything was written. The query below is the actual test. Note the asymmetry worth recording for a collector: you must arm recording BEFORE the window you want, so this API can never retrieve data from a period you did not anticipate.",
            extra: ["requestedDurationSeconds": "\(Int(recordDuration))",
                    "callReturned": recorded ? "true" : "false",
                    "returnsVoid": "true"]
        ))

        // 3-day retrieval.
        let from3 = now.addingTimeInterval(-3 * 86_400)
        var fb = MotionProbeRecorderQuery()
        fb.timedOut = true
        let q = await MotionProbeUtil.offThread(MotionProbe.recorderTimeout, fallback: fb) {
            var r = MotionProbeRecorderQuery()
            guard let list = recorder.accelerometerData(from: from3, to: now) else {
                r.listWasNil = true
                return r
            }
            r.listWasNil = false
            let iterator = NSFastEnumerationIterator(list)
            while let obj = iterator.next() {
                guard let d = obj as? CMRecordedAccelerometerData else { continue }
                r.count += 1
                if r.first == nil { r.first = d.startDate }
                r.last = d.startDate
                if r.count >= 200_000 {
                    r.truncated = true
                    break
                }
            }
            return r
        }

        var qExtra: [String: String] = [
            "requestedFrom": ProbeEnv.iso.string(from: from3),
            "requestedTo": ProbeEnv.iso.string(from: now),
            "requestedSpanDays": "3",
            // On timeout the fallback struct's default would read as "nil list",
            // which is the exact wrong conclusion for a downstream reader.
            "returnedListWasNil": q.timedOut ? "unknown (timed out before the call returned)"
                                             : (q.listWasNil ? "true" : "false"),
            "datumCount": "\(q.count)",
            "iterationCapped": q.truncated ? "true" : "false",
            "iterationCap": "200000",
            "timedOut": q.timedOut ? "true" : "false"
        ]
        if let f = q.first, let l = q.last {
            let span = l.timeIntervalSince(f)
            qExtra["oldestDatumStartDate"] = ProbeEnv.iso.string(from: f)
            qExtra["newestDatumStartDate"] = ProbeEnv.iso.string(from: l)
            qExtra["oldestDatumAge"] = ProbeEnv.age(f) ?? "?"
            qExtra["measuredSpanSeconds"] = String(format: "%.0f", span)
            qExtra["measuredSpanHours"] = String(format: "%.3f", span / 3600.0)
            qExtra["measuredSpanDays"] = String(format: "%.4f", span / 86_400)
            if span > 0 { qExtra["impliedSampleRateHz"] = String(format: "%.2f", Double(q.count - 1) / span) }
        }

        let status: ProbeStatus = {
            if q.timedOut { return .error }
            if q.count > 0 { return .ok }
            if !recAvail { return .unavailable }
            return recAuthorized ? .empty : .denied
        }()

        let value: String = {
            if q.timedOut { return "iteration did not finish in \(Int(MotionProbe.recorderTimeout))s" }
            if q.count > 0 {
                if let f = q.first, let l = q.last {
                    return "\(ProbeEnv.int(q.count)) datum spanning "
                        + "\(String(format: "%.2f", l.timeIntervalSince(f) / 3600.0)) hours"
                }
                return "\(ProbeEnv.int(q.count)) datum"
            }
            return q.listWasNil ? "nil list returned" : "empty list returned"
        }()

        out.append(ProbeItem(
            "motion.sensorRecorder.query",
            "CMSensorRecorder — accelerometerData(from:to:) over 3 days",
            status,
            value: value,
            detail: "THE question this item answers: is there a retrievable 3-day raw ~50 Hz accelerometer archive on this iPhone? The finding is the measured TIME SPAN between the oldest and newest datum, not the raw count — a large count over ten minutes is a short buffer, while even a modest count spread over days is a genuine archive. `impliedSampleRateHz` in `extra` gives the real rate rather than the nominal 50 Hz. A nil or empty list is the expected iPhone outcome and means the firehose does not exist here. Iteration is capped at 200,000 datum with a \(Int(MotionProbe.recorderTimeout))s deadline so a genuinely huge result cannot stall the report; `iterationCapped` records whether that cap bound.",
            extra: qExtra
        ))

        return out
    }
}

// MARK: - MotionProbe private support types
//
// Everything below is prefixed `MotionProbe*` on purpose: all eleven probe
// files compile into one module, and an unprefixed `Box` or `Sample` here
// would collide with another agent's file and break the build.

private final class MotionProbeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}

private enum MotionProbeUtil {

    /// Bridges a callback API into async with a hard deadline and an
    /// exactly-once resume guarantee.
    ///
    /// Deliberately NOT built on `withProbeTimeout`: that helper uses
    /// `withTaskGroup`, which awaits its remaining children when the scope
    /// exits, and `withCheckedContinuation` is not cancellation-aware — so a
    /// continuation that never gets resumed would park the group forever,
    /// exactly the hang it is meant to prevent. A dispatch timer resumes the
    /// continuation instead, and `MotionProbeOnce` guarantees the framework
    /// callback and the timer cannot both resume it.
    static func awaitCallback<T: Sendable>(_ timeout: Double,
                                           fallback: T,
                                           _ body: @escaping (@escaping (T) -> Void) -> Void) async -> T {
        let once = MotionProbeOnce()
        return await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
            let finish: (T) -> Void = { value in
                if once.claim() { cont.resume(returning: value) }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                finish(fallback)
            }
            body(finish)
        }
    }

    /// Runs a synchronous, potentially slow blocking call off-thread with a deadline.
    static func offThread<T: Sendable>(_ timeout: Double,
                                       fallback: T,
                                       _ work: @escaping () -> T) async -> T {
        await awaitCallback(timeout, fallback: fallback) { finish in
            DispatchQueue.global(qos: .userInitiated).async { finish(work()) }
        }
    }

    static func queue(_ name: String) -> OperationQueue {
        let q = OperationQueue()
        q.name = name
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        return q
    }

    static func authName(_ s: CMAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        @unknown default: return "unknown(\(s.rawValue))"
        }
    }

    static func authStatus(_ s: CMAuthorizationStatus) -> ProbeStatus {
        switch s {
        case .authorized: return .ok
        case .denied: return .denied
        case .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .partial
        }
    }

    static func describe(_ error: Error?) -> String? {
        guard let error else { return nil }
        let ns = error as NSError
        return "\(ns.domain) code \(ns.code): \(ns.localizedDescription)"
    }

    static func flag(_ b: Bool) -> String { b ? "yes" : "no" }

    /// Public Objective-C runtime lookup. Used instead of a compile-time
    /// reference for classes Apple declares watchOS-only, where naming the type
    /// in iOS-targeted Swift would fail to build.
    static func classExists(_ name: String) -> Bool {
        NSClassFromString(name) != nil
    }

    static func hasClassMethod(_ className: String, _ selectorName: String) -> Bool {
        guard let cls = NSClassFromString(className) else { return false }
        return class_getClassMethod(cls, NSSelectorFromString(selectorName)) != nil
    }
}

private struct MotionProbePedReading: Sendable {
    var ok = false
    var steps: Int?
    var distanceM: Double?
    var floorsUp: Int?
    var floorsDown: Int?
    var currentPace: Double?
    var averagePace: Double?
    var cadence: Double?
    var start: Date?
    var end: Date?
    var error: String?
    var timedOut = false
}

private struct MotionProbeEventResult: Sendable {
    var received = false
    var date: Date?
    var type: String?
    var error: String?
    var timedOut = false
}

private struct MotionProbeActivitySeg: Sendable {
    var start: Date
    var confidence: Int
    var classes: [String]
}

private struct MotionProbeActivityResult: Sendable {
    var segments: [MotionProbeActivitySeg] = []
    var error: String?
    var timedOut = false
    var returned = false
}

private struct MotionProbeAltitudeSample: Sendable {
    var received = false
    var relativeAltitudeM: Double?
    var pressureKPa: Double?
    var timestamp: TimeInterval?
    var error: String?
    var timedOut = false
}

private struct MotionProbeAbsoluteAltitudeSample: Sendable {
    var received = false
    var altitudeM: Double?
    var accuracy: Double?
    var precision: Double?
    var timestamp: TimeInterval?
    var error: String?
    var timedOut = false
}

private struct MotionProbeHeadphoneSample: Sendable {
    var received = false
    var roll: Double?
    var pitch: Double?
    var yaw: Double?
    var gravityMag: Double?
    var userAccelMag: Double?
    var heading: Double?
    var timestamp: TimeInterval?
    var error: String?
    var timedOut = false
}

private struct MotionProbeRecorderQuery: Sendable {
    var count = 0
    var first: Date?
    var last: Date?
    var listWasNil = true
    var truncated = false
    var timedOut = false
}

private struct MotionProbeSampleStats: Sendable {
    var count = 0
    var hz: Double = 0
    var meanMag: Double = 0
    var minMag: Double = 0
    var maxMag: Double = 0
    var lastX: Double?
    var lastY: Double?
    var lastZ: Double?
    var error: String?
}

/// Thread-safe magnitude accumulator for the raw CMMotionManager streams.
/// Handlers fire on an OperationQueue, so every mutation is behind a lock.
private final class MotionProbeAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var mags: [Double] = []
    private var firstT: TimeInterval?
    private var lastT: TimeInterval?
    private var lx: Double?
    private var ly: Double?
    private var lz: Double?
    private var err: String?
    private var n = 0

    func add(_ x: Double, _ y: Double, _ z: Double, _ t: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        n += 1
        if firstT == nil { firstT = t }
        lastT = t
        lx = x; ly = y; lz = z
        if mags.count < 4_000 {
            mags.append((x * x + y * y + z * z).squareRoot())
        }
    }

    func fail(_ s: String) {
        lock.lock()
        defer { lock.unlock() }
        if err == nil { err = s }
    }

    func stats() -> MotionProbeSampleStats {
        lock.lock()
        defer { lock.unlock() }
        var s = MotionProbeSampleStats()
        s.count = n
        s.lastX = lx; s.lastY = ly; s.lastZ = lz
        s.error = err
        if !mags.isEmpty {
            s.meanMag = mags.reduce(0, +) / Double(mags.count)
            s.minMag = mags.min() ?? 0
            s.maxMag = mags.max() ?? 0
        }
        if let f = firstT, let l = lastT, n > 1, l > f {
            s.hz = Double(n - 1) / (l - f)
        }
        return s
    }
}

private struct MotionProbeDeviceMotionStats: Sendable {
    var count = 0
    var hz: Double = 0
    var fields: [String: String] = [:]
    var error: String?
}

/// Captures the last fused device-motion sample as plain Doubles so nothing
/// non-Sendable crosses a concurrency boundary.
private final class MotionProbeDeviceMotionSink: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    private var firstT: TimeInterval?
    private var lastT: TimeInterval?
    private var fields: [String: String] = [:]
    private var err: String?

    func add(_ dm: CMDeviceMotion) {
        let t = dm.timestamp
        let rad = 180.0 / Double.pi
        let gMag = (dm.gravity.x * dm.gravity.x
                    + dm.gravity.y * dm.gravity.y
                    + dm.gravity.z * dm.gravity.z).squareRoot()
        let uMag = (dm.userAcceleration.x * dm.userAcceleration.x
                    + dm.userAcceleration.y * dm.userAcceleration.y
                    + dm.userAcceleration.z * dm.userAcceleration.z).squareRoot()
        let rMag = (dm.rotationRate.x * dm.rotationRate.x
                    + dm.rotationRate.y * dm.rotationRate.y
                    + dm.rotationRate.z * dm.rotationRate.z).squareRoot()
        let field = dm.magneticField
        let accuracyName: String
        switch field.accuracy {
        case .uncalibrated: accuracyName = "uncalibrated"
        case .low: accuracyName = "low"
        case .medium: accuracyName = "medium"
        case .high: accuracyName = "high"
        @unknown default: accuracyName = "unknown(\(field.accuracy.rawValue))"
        }
        let fMag = (field.field.x * field.field.x
                    + field.field.y * field.field.y
                    + field.field.z * field.field.z).squareRoot()

        var snap: [String: String] = [:]
        snap["attitude.rollDegrees"] = String(format: "%.2f", dm.attitude.roll * rad)
        snap["attitude.pitchDegrees"] = String(format: "%.2f", dm.attitude.pitch * rad)
        snap["attitude.yawDegrees"] = String(format: "%.2f", dm.attitude.yaw * rad)
        snap["gravity.x"] = String(format: "%.4f", dm.gravity.x)
        snap["gravity.y"] = String(format: "%.4f", dm.gravity.y)
        snap["gravity.z"] = String(format: "%.4f", dm.gravity.z)
        snap["gravityMagnitudeG"] = String(format: "%.4f", gMag)
        snap["userAccelerationMagnitudeG"] = String(format: "%.4f", uMag)
        snap["rotationRateMagnitudeRadPerSec"] = String(format: "%.4f", rMag)
        snap["headingDegrees"] = String(format: "%.2f", dm.heading)
        snap["calibratedMagneticFieldMagnitudeMicroTesla"] = String(format: "%.2f", fMag)
        snap["calibratedMagneticFieldAccuracy"] = accuracyName

        lock.lock()
        defer { lock.unlock() }
        n += 1
        if firstT == nil { firstT = t }
        lastT = t
        fields = snap
    }

    func fail(_ s: String) {
        lock.lock()
        defer { lock.unlock() }
        if err == nil { err = s }
    }

    func snapshot() -> MotionProbeDeviceMotionStats {
        lock.lock()
        defer { lock.unlock() }
        var s = MotionProbeDeviceMotionStats()
        s.count = n
        s.fields = fields
        s.error = err
        if let f = firstT, let l = lastT, n > 1, l > f {
            s.hz = Double(n - 1) / (l - f)
        }
        return s
    }
}
