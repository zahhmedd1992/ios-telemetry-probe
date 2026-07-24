import Foundation
import UIKit
import AVFoundation
import AVFAudio
import CoreMedia
import SoundAnalysis

#if canImport(ARKit)
import ARKit
#endif

#if canImport(WeatherKit)
import WeatherKit
#endif

#if canImport(SensorKit)
import SensorKit
#endif

// MARK: - AmbientProbe
//
// "Ambient environment" = everything the phone can tell us about the physical
// space it is sitting in, WITHOUT us shipping a camera preview or a live ARKit
// session. Concretely: how loud the room is, what audio hardware is attached,
// what the sound classifier knows how to recognise, how much light the camera
// thinks it needs, how bright the screen is, and whether the two research-grade
// firehoses (WeatherKit, SensorKit) are reachable from a personal Apple ID.
//
// Two things this probe deliberately does NOT do, and both are findings:
//   * It never starts an ARSession. Ambient lux / colour temperature only exist
//     inside a running foreground camera session; standing one up mid-probe
//     would blast the camera indicator, steal the audio route, and take 1-2s of
//     tracking warm-up for one number.
//   * It never mutates UIScreen.brightness. Setting it programmatically turns
//     Auto-Brightness OFF persistently in Settings. A probe must not degrade the
//     device it measures.
//
// Barometric pressure is the other classic ambient signal. It is CMAltimeter,
// it lives in MotionProbe, and it is cross-referenced (not duplicated) here.

struct AmbientProbe: TelemetryProbe {
    let key = "ambient"
    let title = "Ambient Environment"

    // 0 dBFS is assumed to correspond to this many dB SPL. This is a GUESS.
    // The real full-scale point of an iPhone mic is nearer 120-130 dB SPL and
    // varies by model, by port (bottom/front/back), and by AVAudioSession mode.
    // The number is recorded in `extra` so a future collector can recalibrate
    // every historical reading with a single arithmetic shift.
    static let splOffsetDB: Double = 94.0

    // How long we hold the mic open, and how often we sample the meters.
    static let micSeconds: Double = 2.0
    static let micPollHz: Double = 10.0

    func run() async -> ProbeSection {
        var items: [ProbeItem] = []

        items.append(contentsOf: await runMicrophone())
        items.append(contentsOf: runSoundAnalysis())
        items.append(contentsOf: await runARKit())
        items.append(contentsOf: runCamera())
        items.append(contentsOf: await runScreen())
        items.append(contentsOf: runWeather())
        items.append(contentsOf: await runSensorKit())
        items.append(runPressureCrossReference())

        return section(AmbientProbeSummary.build(items), items)
    }
}

// MARK: - Exactly-once continuation plumbing
//
// Every callback API below is wrapped so the continuation is resumed exactly
// once on every path, including "the callback never fires". A bare
// withCheckedContinuation nested inside withProbeTimeout is NOT safe: the
// contract's helper uses withTaskGroup, which implicitly awaits its remaining
// children when the body returns, so an unresumed continuation would hang the
// whole report rather than time out. The deadline therefore lives INSIDE the
// continuation, not outside it.

final class AmbientProbeResumeGuard: @unchecked Sendable {
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

enum AmbientProbeAwait {
    /// Bridges a completion-handler API into async with a hard internal deadline.
    static func once<T>(timeout: Double,
                        timeoutValue: T,
                        _ body: @escaping (@escaping (T) -> Void) -> Void) async -> T {
        await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
            let guardBox = AmbientProbeResumeGuard()
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                if guardBox.claim() { cont.resume(returning: timeoutValue) }
            }
            body { value in
                if guardBox.claim() { cont.resume(returning: value) }
            }
        }
    }
}

// MARK: - Small formatting helpers (prefixed; do not un-prefix)

enum AmbientProbeFmt {
    static func db(_ v: Float) -> String { String(format: "%.1f dBFS", v) }
    static func f2(_ v: Double) -> String { String(format: "%.2f", v) }
    static func f3(_ v: Double) -> String { String(format: "%.3f", v) }
    static func f4(_ v: Double) -> String { String(format: "%.4f", v) }
    static func bool(_ b: Bool) -> String { b ? "true" : "false" }
    static func secs(_ t: CMTime) -> String {
        let s = CMTimeGetSeconds(t)
        if s.isNaN || s.isInfinite { return "n/a" }
        if s < 0.001 { return String(format: "%.1f µs", s * 1_000_000) }
        if s < 1 { return String(format: "%.3f ms", s * 1000) }
        return String(format: "%.3f s", s)
    }
}

// MARK: - 1. Microphone ambient level + audio route

struct AmbientProbeMicReading {
    var started = false
    var avgPeak: Float = -160     // mean of averagePower samples
    var maxPeak: Float = -160     // max of peakPower samples
    var minAvg: Float = 0
    var maxAvg: Float = -160
    var samples = 0
    var startError: String?
}

extension AmbientProbe {

    func runMicrophone() async -> [ProbeItem] {
        var items: [ProbeItem] = []
        let session = AVAudioSession.sharedInstance()

        // --- Read PRE-configuration state first. availableInputs is nil until
        // the session category permits recording, so a single late read would
        // look identical to "this device has no inputs".
        let preInputs = session.availableInputs
        let preOtherAudio = session.isOtherAudioPlaying
        let preCategory = session.category.rawValue
        let preMode = session.mode.rawValue

        items.append(ProbeItem(
            "ambient.audio.inputsBeforeConfigure",
            "availableInputs (before configuring for record)",
            preInputs == nil ? .empty : .ok,
            value: preInputs == nil ? "nil" : "\(preInputs?.count ?? 0) input(s)",
            detail: "AVAudioSession.availableInputs returns nil until the category allows recording. Read here on purpose so the post-configure read below can be compared — a single read at the wrong moment reports a false 'no microphone'.",
            extra: [
                "categoryBefore": preCategory,
                "modeBefore": preMode,
                "isOtherAudioPlaying": AmbientProbeFmt.bool(preOtherAudio)
            ]
        ))

        items.append(ProbeItem(
            "ambient.audio.otherAudioPlaying",
            "Other audio playing (pre-activation)",
            .ok,
            value: AmbientProbeFmt.bool(preOtherAudio),
            detail: "Sampled BEFORE we activate a .record session, because activation itself can interrupt other audio and would make this read a self-fulfilling false."
        ))

        // --- Permission.
        let priorPermission = AVAudioApplication.shared.recordPermission
        let priorText = AmbientProbeMicPermission.describe(priorPermission)

        let granted: Bool = await AmbientProbeAwait.once(timeout: 60, timeoutValue: false) { done in
            // iOS 17+ API. The deployment target IS 17.0, so the documented
            // pre-17 fallback (AVAudioSession.sharedInstance().requestRecordPermission)
            // is unreachable dead code here and is deliberately not compiled in —
            // it would only add a deprecation warning.
            AVAudioApplication.requestRecordPermission { ok in done(ok) }
        }

        let afterPermission = AVAudioApplication.shared.recordPermission
        let permStatus: ProbeStatus
        switch afterPermission {
        case .granted: permStatus = .ok
        case .denied: permStatus = .denied
        case .undetermined: permStatus = .notDetermined
        @unknown default: permStatus = .partial
        }

        items.append(ProbeItem(
            "ambient.mic.permission",
            "Microphone permission",
            permStatus,
            value: AmbientProbeMicPermission.describe(afterPermission),
            detail: "Authorization status is recorded separately from whether audio data actually arrived — those two disagree often enough that the disagreement is the interesting part. Requested via AVAudioApplication.requestRecordPermission (iOS 17+).",
            extra: [
                "statusBeforeRequest": priorText,
                "statusAfterRequest": AmbientProbeMicPermission.describe(afterPermission),
                "requestCallbackGranted": AmbientProbeFmt.bool(granted),
                "api": "AVAudioApplication.requestRecordPermission(completionHandler:)"
            ]
        ))

        guard afterPermission == .granted else {
            items.append(ProbeItem(
                "ambient.mic.level",
                "Ambient sound level",
                permStatus == .denied ? .denied : .notDetermined,
                detail: "No level measured: record permission is \(AmbientProbeMicPermission.describe(afterPermission)). The session was never configured, so the audio route items below are also skipped."
            ))
            return items
        }

        // --- Configure the session for measurement.
        // .measurement mode is the important part: it asks the system to leave
        // the signal alone (no AGC, no EQ, no voice processing), which is the
        // difference between measuring the room and measuring Apple's DSP.
        var configError: String?
        do {
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true, options: [])
        } catch {
            configError = "\(error)"
        }

        if let configError {
            items.append(ProbeItem(
                "ambient.audio.configure",
                "Configure AVAudioSession (.record / .measurement)",
                .error,
                detail: configError
            ))
            // Still try to leave the session clean.
            let deact = AmbientProbe.deactivate(session)
            items.append(deact)
            return items
        }

        items.append(ProbeItem(
            "ambient.audio.configure",
            "Configure AVAudioSession (.record / .measurement)",
            .ok,
            value: "\(session.category.rawValue) / \(session.mode.rawValue)",
            detail: ".measurement mode disables automatic gain control and other input processing, so the dBFS numbers describe the room rather than Apple's signal chain.",
            extra: [
                "sampleRate": AmbientProbeFmt.f2(session.sampleRate),
                "ioBufferDuration": AmbientProbeFmt.f4(session.ioBufferDuration),
                "inputLatencySeconds": AmbientProbeFmt.f4(session.inputLatency),
                "outputLatencySeconds": AmbientProbeFmt.f4(session.outputLatency),
                "inputNumberOfChannels": "\(session.inputNumberOfChannels)",
                "outputNumberOfChannels": "\(session.outputNumberOfChannels)",
                "maximumInputNumberOfChannels": "\(session.maximumInputNumberOfChannels)",
                "inputGain": AmbientProbeFmt.f3(Double(session.inputGain)),
                "isInputGainSettable": AmbientProbeFmt.bool(session.isInputGainSettable)
            ]
        ))

        // --- Post-configure availableInputs. THIS is the connected-hardware list.
        let postInputs = session.availableInputs ?? []
        var inputExtra: [String: String] = [
            "count": "\(postInputs.count)",
            "countBeforeConfigure": preInputs == nil ? "nil" : "\(preInputs?.count ?? 0)"
        ]
        for (i, p) in postInputs.enumerated() {
            inputExtra["input\(i).portType"] = p.portType.rawValue
            inputExtra["input\(i).portName"] = p.portName
            inputExtra["input\(i).uid"] = p.uid
            inputExtra["input\(i).channels"] = "\(p.channels?.count ?? 0)"
            inputExtra["input\(i).dataSources"] = "\(p.dataSources?.count ?? 0)"
            if let ds = p.selectedDataSource {
                inputExtra["input\(i).selectedDataSource"] = ds.dataSourceName
            }
            if let names = p.dataSources?.map({ $0.dataSourceName }), !names.isEmpty {
                inputExtra["input\(i).dataSourceNames"] = names.joined(separator: ", ")
            }
        }
        items.append(ProbeItem(
            "ambient.audio.availableInputs",
            "Available audio inputs (after configuring)",
            postInputs.isEmpty ? .empty : .ok,
            value: postInputs.isEmpty ? "none" : postInputs.map { $0.portType.rawValue }.joined(separator: ", "),
            detail: "Every attached input, not just the selected one. This is hardware telemetry in its own right: a 'BluetoothHFP' entry names a headset, 'CarAudio' names a vehicle, and the per-port data sources on the built-in mic expose the physical mic array (bottom / front / back).",
            extra: inputExtra
        ))

        // --- Current input port (which mic is actually live).
        let route = session.currentRoute
        let inPorts = route.inputs
        var curInExtra: [String: String] = ["count": "\(inPorts.count)"]
        for (i, p) in inPorts.enumerated() {
            curInExtra["port\(i).type"] = p.portType.rawValue
            curInExtra["port\(i).name"] = p.portName
            curInExtra["port\(i).uid"] = p.uid
            curInExtra["port\(i).channels"] = "\(p.channels?.count ?? 0)"
            if let ds = p.selectedDataSource {
                curInExtra["port\(i).selectedDataSource"] = ds.dataSourceName
                curInExtra["port\(i).orientation"] = ds.orientation?.rawValue ?? "n/a"
                curInExtra["port\(i).polarPattern"] = ds.selectedPolarPattern?.rawValue ?? "n/a"
            }
        }
        if let preferred = session.preferredInput {
            curInExtra["preferredInput"] = preferred.portType.rawValue
        }
        items.append(ProbeItem(
            "ambient.audio.currentInput",
            "Current input port",
            inPorts.isEmpty ? .empty : .ok,
            value: inPorts.first.map { "\($0.portType.rawValue) — \($0.portName)" } ?? "none",
            detail: "Identifies the physical device capturing the sample below. 'BuiltInMic' vs 'BluetoothHFP' (AirPods) vs 'CarAudio' completely changes what the dBFS number means, so it must travel with the reading.",
            extra: curInExtra
        ))

        // --- Take the actual level sample.
        let reading = await AmbientProbe.sampleMicLevel(session: session)

        if reading.started, reading.samples > 0 {
            let spl = Double(reading.avgPeak) + AmbientProbe.splOffsetDB
            let splPeak = Double(reading.maxPeak) + AmbientProbe.splOffsetDB
            items.append(ProbeItem(
                "ambient.mic.level",
                "Ambient sound level",
                .ok,
                value: "avg \(AmbientProbeFmt.db(reading.avgPeak)) · peak \(AmbientProbeFmt.db(reading.maxPeak)) · ≈\(String(format: "%.0f", spl)) dB SPL (UNCALIBRATED)",
                detail: "\(reading.samples) meter reads over \(AmbientProbeFmt.f2(AmbientProbe.micSeconds))s at \(String(format: "%.0f", AmbientProbe.micPollHz)) Hz, recorded to /dev/null so nothing is written to disk. dBFS is exact. The SPL figure is NOT: it is literally dBFS + \(AmbientProbeFmt.f2(AmbientProbe.splOffsetDB)), assuming 0 dBFS ≡ \(AmbientProbeFmt.f2(AmbientProbe.splOffsetDB)) dB SPL (1 Pa). A real iPhone mic clips nearer 120-130 dB SPL and the offset varies by model, by which mic in the array is selected, and by session mode. Treat SPL as ordinal, not absolute — it is only comparable against other readings from this same device. The offset is stored in extra so every historical reading can be recalibrated with one shift.",
                extra: [
                    "averagePowerDBFS": String(format: "%.2f", reading.avgPeak),
                    "peakPowerDBFS": String(format: "%.2f", reading.maxPeak),
                    "minAveragePowerDBFS": String(format: "%.2f", reading.minAvg),
                    "maxAveragePowerDBFS": String(format: "%.2f", reading.maxAvg),
                    "estimatedDBSPL": String(format: "%.1f", spl),
                    "estimatedPeakDBSPL": String(format: "%.1f", splPeak),
                    "splOffsetAssumedDB": String(format: "%.1f", AmbientProbe.splOffsetDB),
                    "splFormula": "dBSPL = dBFS + splOffsetAssumedDB",
                    "calibrated": "false",
                    "durationSeconds": String(format: "%.2f", AmbientProbe.micSeconds),
                    "pollHz": String(format: "%.0f", AmbientProbe.micPollHz),
                    "meterSamples": "\(reading.samples)",
                    "recordedAt": ProbeEnv.stamp(Date()) ?? "?",
                    "destination": "/dev/null",
                    "format": "kAudioFormatAppleLossless 44100 Hz mono"
                ]
            ))
        } else {
            items.append(ProbeItem(
                "ambient.mic.level",
                "Ambient sound level",
                .error,
                value: reading.started ? "no meter samples" : "recorder never started",
                detail: reading.startError ?? "AVAudioRecorder.record() returned false. Deliberately NOT reporting a level here: an unstarted recorder returns -160 dBFS forever, which reads as a perfectly plausible silent room and would poison the dataset with fake silence.",
                extra: [
                    "recorderStarted": AmbientProbeFmt.bool(reading.started),
                    "meterSamples": "\(reading.samples)"
                ]
            ))
        }

        // --- Output side.
        items.append(ProbeItem(
            "ambient.audio.outputVolume",
            "System output volume",
            .ok,
            value: String(format: "%.3f (0-1)", session.outputVolume),
            detail: "AVAudioSession.outputVolume is the system-wide media volume, readable without any entitlement and without the volume HUD appearing.",
            extra: [
                "outputVolume": String(format: "%.4f", session.outputVolume),
                "percent": String(format: "%.0f%%", session.outputVolume * 100)
            ]
        ))

        let outPorts = route.outputs
        var outExtra: [String: String] = ["count": "\(outPorts.count)"]
        for (i, p) in outPorts.enumerated() {
            outExtra["port\(i).type"] = p.portType.rawValue
            outExtra["port\(i).name"] = p.portName
            outExtra["port\(i).uid"] = p.uid
            outExtra["port\(i).channels"] = "\(p.channels?.count ?? 0)"
        }
        items.append(ProbeItem(
            "ambient.audio.outputRoute",
            "Current output route",
            outPorts.isEmpty ? .empty : .ok,
            value: outPorts.isEmpty ? "none" : outPorts.map { $0.portType.rawValue }.joined(separator: ", "),
            detail: "Route port types name attached hardware without any Bluetooth entitlement: 'BluetoothA2DP' + port name gives you the headphone model, 'CarAudio' says the user is in a vehicle, 'AirPlay' names a room. Note this route was read while the session was in .record, which can differ from the idle playback route.",
            extra: outExtra
        ))

        // --- Always tear the session down, on every path.
        items.append(AmbientProbe.deactivate(session))

        return items
    }

    /// Deactivates the session and reports whether the teardown itself failed.
    /// ProbeRunner runs all eleven probes sequentially in one process, so a
    /// left-active .record session is downstream contamination for every probe
    /// after this one.
    static func deactivate(_ session: AVAudioSession) -> ProbeItem {
        var err: String?
        do {
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            err = "\(error)"
        }
        return ProbeItem(
            "ambient.audio.deactivate",
            "Deactivate AVAudioSession",
            err == nil ? .ok : .error,
            value: err == nil ? "clean" : "failed",
            detail: err ?? "setActive(false, .notifyOthersOnDeactivation) succeeded; whatever audio we interrupted was told it may resume. Reported explicitly because probes run sequentially in one process and a leaked .record session would corrupt every section after this one."
        )
    }

    /// Records to /dev/null with metering on and polls the meters. Returns a
    /// reading whose `started` flag is authoritative — never infer silence from
    /// a -160 dBFS value alone.
    static func sampleMicLevel(session: AVAudioSession) async -> AmbientProbeMicReading {
        var out = AmbientProbeMicReading()

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatAppleLossless),
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue
        ]

        let url = URL(fileURLWithPath: "/dev/null")
        guard let recorder = try? AVAudioRecorder(url: url, settings: settings) else {
            out.startError = "AVAudioRecorder(url:settings:) threw — could not construct a recorder for /dev/null with AppleLossless @ 44.1 kHz mono."
            return out
        }

        recorder.isMeteringEnabled = true
        guard recorder.prepareToRecord() else {
            out.startError = "AVAudioRecorder.prepareToRecord() returned false."
            return out
        }
        guard recorder.record() else {
            out.startError = "AVAudioRecorder.record() returned false. No level is reported, because an unstarted recorder meters -160 dBFS indefinitely and that is indistinguishable from a genuinely silent room."
            return out
        }
        out.started = true

        let interval = 1.0 / micPollHz
        let deadline = Date().addingTimeInterval(micSeconds)
        var avgSum: Double = 0
        var n = 0
        var maxPeak: Float = -160
        var minAvg: Float = 0
        var maxAvg: Float = -160

        // Discard the first ~150 ms: the input chain is still ramping and the
        // very first meter read is pre-roll, not room noise.
        try? await Task.sleep(nanoseconds: 150_000_000)

        while Date() < deadline {
            recorder.updateMeters()
            let a = recorder.averagePower(forChannel: 0)
            let p = recorder.peakPower(forChannel: 0)
            if a.isFinite {
                avgSum += Double(a)
                n += 1
                if a < minAvg { minAvg = a }
                if a > maxAvg { maxAvg = a }
            }
            if p.isFinite, p > maxPeak { maxPeak = p }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }

        recorder.stop()

        out.samples = n
        out.avgPeak = n > 0 ? Float(avgSum / Double(n)) : -160
        out.maxPeak = maxPeak
        out.minAvg = minAvg
        out.maxAvg = maxAvg
        return out
    }
}

enum AmbientProbeMicPermission {
    static func describe(_ p: AVAudioApplication.recordPermission) -> String {
        switch p {
        case .undetermined: return "undetermined"
        case .denied: return "denied"
        case .granted: return "granted"
        @unknown default: return "unknown(\(p.rawValue))"
        }
    }
}

// MARK: - 2. SoundAnalysis built-in classifier

extension AmbientProbe {

    func runSoundAnalysis() -> [ProbeItem] {
        var items: [ProbeItem] = []

        guard let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) else {
            items.append(ProbeItem(
                "ambient.soundanalysis.classifier",
                "SNClassifySoundRequest(.version1)",
                .error,
                value: "could not construct",
                detail: "SNClassifySoundRequest(classifierIdentifier: .version1) threw. The Apple-supplied sound classifier ships inside SoundAnalysis and needs no model file, no download, and no entitlement — so a failure here means the framework itself is unusable on this device, which would be a genuine finding."
            ))
            return items
        }

        let labels = request.knownClassifications
        let count = labels.count

        // The documented figure is "over 300 sounds". Report the MEASURED count
        // as the value and keep the claim in detail — checking documentation
        // against one specific device is the entire premise of this app.
        let sample = Array(labels.prefix(30)).joined(separator: ", ")

        // Which privacy-relevant labels does the shipped model actually carry?
        // Substring match, because Apple's identifiers are compound
        // (e.g. "water_tap_faucet", "crying_sobbing").
        let probeFor = [
            "speech", "shout", "whispering", "laughter", "crying", "cough", "sneeze",
            "snoring", "breathing", "singing", "typing", "keyboard", "door",
            "dishes", "water", "toilet", "shower", "vacuum", "microwave",
            "siren", "car_horn", "train", "aircraft", "helicopter", "motorcycle",
            "dog", "cat", "bird", "baby", "glass", "gunshot", "applause",
            "music", "television", "telephone", "alarm", "smoke_detector",
            "footsteps", "chewing", "drill", "hammer", "lawn_mower", "rain", "thunder"
        ]
        var hits: [String] = []
        var misses: [String] = []
        for term in probeFor {
            let matched = labels.filter { $0.localizedCaseInsensitiveContains(term) }
            if matched.isEmpty {
                misses.append(term)
            } else {
                hits.append("\(term)→\(matched.prefix(3).joined(separator: "|"))")
            }
        }

        var extra: [String: String] = [
            "knownClassificationsCount": "\(count)",
            "documentedClaim": "Apple documents 'over 300 sounds' for .version1",
            "claimHolds": count > 300 ? "true" : "false",
            "classifierIdentifier": "version1",
            "liveClassificationRun": "false",
            "probeTermsTested": "\(probeFor.count)",
            "probeTermsMatched": "\(hits.count)",
            "probeTermsAbsent": misses.isEmpty ? "none" : misses.joined(separator: ", ")
        ]
        if !hits.isEmpty { extra["notableMatches"] = hits.joined(separator: "; ") }
        // Full list, so the exact vocabulary of this SDK is captured verbatim.
        extra["allClassifications"] = labels.joined(separator: ",")

        items.append(ProbeItem(
            "ambient.soundanalysis.classifier",
            "Built-in sound classifier vocabulary",
            count > 0 ? .ok : .empty,
            value: "\(ProbeEnv.int(count)) known classifications",
            detail: "The classifier CONSTRUCTS, which is the first finding — no model download, no entitlement, no permission. Apple documents 'over 300 sounds'; this device's SDK reports \(ProbeEnv.int(count)). First 30 labels: \(sample). The full vocabulary is in extra.allClassifications. No live classification was run: that would require holding the mic open a second time and feeding SNAudioStreamAnalyzer, and the vocabulary — not the result — is what a collector needs to know up front.",
            extra: extra
        ))

        items.append(ProbeItem(
            "ambient.soundanalysis.liveAnalysis",
            "Live sound classification",
            .partial,
            value: "not run (by design)",
            detail: "SNAudioStreamAnalyzer + SNResultsObserving over an AVAudioEngine input tap would classify the room in real time using only public API and only the existing mic permission. Deliberately skipped in this probe: it needs a second mic session, it produces a result that is meaningless without knowing the room, and the capability question — 'does the classifier exist and what does it know' — is already answered above."
        ))

        return items
    }
}

// MARK: - 3. ARKit light estimation reachability

extension AmbientProbe {

    func runARKit() async -> [ProbeItem] {
        var items: [ProbeItem] = []

        #if canImport(ARKit)
        // ARKit statics are evaluated on the main actor: several ARKit types
        // gained @MainActor isolation in recent SDKs and hopping is free here.
        let caps: [String: String] = await MainActor.run {
            var d: [String: String] = [:]
            d["ARConfiguration.isSupported"] = AmbientProbeFmt.bool(ARConfiguration.isSupported)
            d["ARWorldTrackingConfiguration.isSupported"] = AmbientProbeFmt.bool(ARWorldTrackingConfiguration.isSupported)
            d["ARFaceTrackingConfiguration.isSupported"] = AmbientProbeFmt.bool(ARFaceTrackingConfiguration.isSupported)
            d["ARBodyTrackingConfiguration.isSupported"] = AmbientProbeFmt.bool(ARBodyTrackingConfiguration.isSupported)
            d["supportsSceneReconstruction.mesh"] = AmbientProbeFmt.bool(
                ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh))
            d["supportsFrameSemantics.sceneDepth"] = AmbientProbeFmt.bool(
                ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth))
            d["supportsFrameSemantics.smoothedSceneDepth"] = AmbientProbeFmt.bool(
                ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth))
            d["supportsFrameSemantics.personSegmentation"] = AmbientProbeFmt.bool(
                ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentation))
            d["worldTracking.videoFormats"] = "\(ARWorldTrackingConfiguration.supportedVideoFormats.count)"
            return d
        }

        let worldSupported = caps["ARWorldTrackingConfiguration.isSupported"] == "true"
        let baseSupported = caps["ARConfiguration.isSupported"] == "true"

        items.append(ProbeItem(
            "ambient.arkit.support",
            "ARKit configuration support",
            worldSupported ? .ok : .unavailable,
            value: worldSupported ? "world tracking supported" : "world tracking NOT supported",
            detail: "ARConfiguration.isSupported (the abstract base class property, iOS 11+) reports \(baseSupported); ARWorldTrackingConfiguration.isSupported reports \(worldSupported). supportsSceneReconstruction(.mesh) is the practical LiDAR test on this hardware.",
            extra: caps
        ))

        items.append(ProbeItem(
            "ambient.arkit.lightEstimate",
            "Ambient lux / colour temperature (ARFrame.lightEstimate)",
            worldSupported ? .partial : .unavailable,
            value: worldSupported ? "reachable, NOT sampled" : "hardware does not support it",
            detail: "ARFrame.lightEstimate.ambientIntensity (lumens, ~0-2000, 1000 = 'neutral') and .ambientColorTemperature (Kelvin, ~6500 neutral) are the closest thing iOS has to a public ambient-light sensor reading — the real ALS behind the status bar is SensorKit-only. The hard constraint: they exist ONLY on a delivered ARFrame, which means an ARSession must be RUNNING, in the FOREGROUND, with the CAMERA ACTIVE. There is no snapshot call. Cost of one reading: the camera privacy indicator lights up, the audio route can be seized, and world tracking needs 1-2 seconds of warm-up before lightEstimate is non-nil. This probe therefore reports reachability only and never starts a session. A dedicated foreground 'lux capture' screen is the correct home for this, not a background report run. Set ARWorldTrackingConfiguration.isLightEstimationEnabled = true (it defaults to true) or lightEstimate is nil regardless.",
            extra: [
                "requiresRunningSession": "true",
                "requiresForeground": "true",
                "requiresCamera": "true",
                "sessionStartedByThisProbe": "false",
                "ambientIntensityUnit": "lumens",
                "ambientColorTemperatureUnit": "Kelvin",
                "neutralIntensityReference": "1000",
                "neutralColorTemperatureReference": "6500",
                "enableFlag": "ARConfiguration.isLightEstimationEnabled (default true)",
                "directionalVariant": "ARDirectionalLightEstimate (face tracking only, adds spherical harmonics)"
            ]
        ))
        #else
        items.append(ProbeItem(
            "ambient.arkit.support",
            "ARKit configuration support",
            .unavailable,
            detail: "canImport(ARKit) is false on this SDK/platform, so no light-estimation path exists at all."
        ))
        #endif

        return items
    }
}

// MARK: - 4. AVCaptureDevice as an ambient-light proxy (no session started)

extension AmbientProbe {

    func runCamera() -> [ProbeItem] {
        var items: [ProbeItem] = []

        // Pure read. Does NOT prompt, does NOT call requestAccess.
        let auth = AVCaptureDevice.authorizationStatus(for: .video)
        let authText: String
        let authStatus: ProbeStatus
        switch auth {
        case .authorized: authText = "authorized"; authStatus = .ok
        case .denied: authText = "denied"; authStatus = .denied
        case .restricted: authText = "restricted"; authStatus = .denied
        case .notDetermined: authText = "notDetermined"; authStatus = .notDetermined
        @unknown default: authText = "unknown(\(auth.rawValue))"; authStatus = .partial
        }
        items.append(ProbeItem(
            "ambient.camera.authorization",
            "Camera authorization status",
            authStatus,
            value: authText,
            detail: "Read only — requestAccess(for:) is deliberately not called, because everything below is readable from the AVCaptureDevice object with no permission and no session. Note the finding: camera HARDWARE capability is fully enumerable while permission is still notDetermined.",
            extra: ["api": "AVCaptureDevice.authorizationStatus(for: .video)", "promptShown": "false"]
        ))

        var deviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .builtInUltraWideCamera,
            .builtInTelephotoCamera,
            .builtInDualCamera,
            .builtInDualWideCamera,
            .builtInTripleCamera,
            .builtInTrueDepthCamera
        ]
        if #available(iOS 15.4, *) {
            deviceTypes.append(.builtInLiDARDepthCamera)
        }

        let allDevices = AmbientProbeCameraDiscovery.devices(deviceTypes)
        let backDevices = allDevices.filter { $0.position == .back }
        let frontDevices = allDevices.filter { $0.position == .front }

        var invExtra: [String: String] = [
            "totalDiscovered": "\(allDevices.count)",
            "backCount": "\(backDevices.count)",
            "frontCount": "\(frontDevices.count)",
            "sessionStarted": "false"
        ]
        for (i, d) in allDevices.enumerated() {
            invExtra["device\(i).uniqueID"] = d.uniqueID
            invExtra["device\(i).localizedName"] = d.localizedName
            invExtra["device\(i).deviceType"] = d.deviceType.rawValue
            invExtra["device\(i).position"] = AmbientProbeCameraPosition.describe(d.position)
            invExtra["device\(i).formats"] = "\(d.formats.count)"
            invExtra["device\(i).hasTorch"] = AmbientProbeFmt.bool(d.hasTorch)
            invExtra["device\(i).hasFlash"] = AmbientProbeFmt.bool(d.hasFlash)
        }

        items.append(ProbeItem(
            "ambient.camera.inventory",
            "Discoverable capture devices",
            allDevices.isEmpty ? .unavailable : .ok,
            value: "\(allDevices.count) device(s): \(allDevices.map { $0.deviceType.rawValue }.joined(separator: ", "))",
            detail: "AVCaptureDevice.DiscoverySession enumerates the full camera array with no session, no permission prompt, and no camera indicator. A 'builtInLiDARDepthCamera' entry here is a hardware fingerprint (Pro models only).",
            extra: invExtra
        ))

        // The exposure envelope MUST come from a real photographic camera. With
        // mediaType nil the inventory can include depth cameras, whose format
        // has no video dimensions and a meaningless ISO range — if one of those
        // sorted first we would publish 0x0 and a garbage envelope as the
        // headline number. Prefer the back wide-angle explicitly.
        let envelopeDevice = backDevices.first(where: { $0.deviceType == .builtInWideAngleCamera })
            ?? backDevices.first(where: { $0.deviceType != .builtInTrueDepthCamera })
            ?? backDevices.first
            ?? allDevices.first(where: { $0.deviceType == .builtInWideAngleCamera })
            ?? allDevices.first

        guard let back = envelopeDevice else {
            items.append(ProbeItem(
                "ambient.camera.backFormat",
                "Back camera exposure envelope",
                .unavailable,
                detail: "No back-facing capture device was discoverable, so no ISO / exposure envelope could be read."
            ))
            return items
        }

        // --- CAPABILITY data. This is real and session-independent.
        let fmt = back.activeFormat
        let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
        let frameRates = fmt.videoSupportedFrameRateRanges
        let maxFPS = frameRates.map { $0.maxFrameRate }.max() ?? 0
        let minFPS = frameRates.map { $0.minFrameRate }.min() ?? 0

        // Widest envelope across ALL formats, not just the active one — that is
        // the true low-light floor and bright-light ceiling of the sensor.
        let allMinISO = back.formats.map { $0.minISO }.min() ?? fmt.minISO
        let allMaxISO = back.formats.map { $0.maxISO }.max() ?? fmt.maxISO
        let allMaxExposure = back.formats
            .map { CMTimeGetSeconds($0.maxExposureDuration) }
            .filter { $0.isFinite }
            .max() ?? CMTimeGetSeconds(fmt.maxExposureDuration)
        let allMinExposure = back.formats
            .map { CMTimeGetSeconds($0.minExposureDuration) }
            .filter { $0.isFinite && $0 > 0 }
            .min() ?? CMTimeGetSeconds(fmt.minExposureDuration)

        items.append(ProbeItem(
            "ambient.camera.backFormat",
            "Back camera exposure envelope (\(back.localizedName))",
            .ok,
            value: "ISO \(AmbientProbeFmt.f2(Double(fmt.minISO)))–\(AmbientProbeFmt.f2(Double(fmt.maxISO))) · exposure \(AmbientProbeFmt.secs(fmt.minExposureDuration))–\(AmbientProbeFmt.secs(fmt.maxExposureDuration))",
            detail: "Read straight off the AVCaptureDevice / activeFormat with NO session running and NO camera permission — this is capability data, not a light measurement. It matters because it bounds the camera-as-lux-meter idea: with a session running, the auto-exposure pair (ISO × exposureDuration) plus exposureTargetOffset is a usable relative-brightness proxy, and these min/max values define its dynamic range. 'activeFormat' with no session is the device's default format, which is not necessarily the format a real capture session would negotiate.",
            extra: [
                "deviceUniqueID": back.uniqueID,
                "deviceType": back.deviceType.rawValue,
                "deviceSelection": "back builtInWideAngleCamera preferred; depth cameras excluded because their format carries no video dimensions or meaningful ISO range",
                "position": AmbientProbeCameraPosition.describe(back.position),
                "activeFormat.minISO": String(format: "%.3f", fmt.minISO),
                "activeFormat.maxISO": String(format: "%.3f", fmt.maxISO),
                "activeFormat.minExposureDurationSeconds": String(format: "%.9f", CMTimeGetSeconds(fmt.minExposureDuration)),
                "activeFormat.maxExposureDurationSeconds": String(format: "%.6f", CMTimeGetSeconds(fmt.maxExposureDuration)),
                "activeFormat.dimensions": "\(dims.width)x\(dims.height)",
                "activeFormat.maxFrameRate": String(format: "%.2f", maxFPS),
                "activeFormat.minFrameRate": String(format: "%.2f", minFPS),
                "activeFormat.videoHDRSupported": AmbientProbeFmt.bool(fmt.isVideoHDRSupported),
                "allFormats.count": "\(back.formats.count)",
                "allFormats.minISO": String(format: "%.3f", allMinISO),
                "allFormats.maxISO": String(format: "%.3f", allMaxISO),
                "allFormats.minExposureDurationSeconds": String(format: "%.9f", allMinExposure),
                "allFormats.maxExposureDurationSeconds": String(format: "%.6f", allMaxExposure),
                "isoDynamicRangeStops": String(format: "%.2f", log2(Double(max(allMaxISO, 1)) / Double(max(allMinISO, 1)))),
                "sessionStarted": "false",
                "permissionRequired": "false"
            ]
        ))

        // --- Live-ish values. These are DEFAULTS, not a measurement, and are
        // labelled as such so the section cannot be misread as a lux reading.
        items.append(ProbeItem(
            "ambient.camera.liveExposure",
            "Back camera current ISO / exposure",
            .partial,
            value: "ISO \(AmbientProbeFmt.f2(Double(back.iso))) · \(AmbientProbeFmt.secs(back.exposureDuration)) — NOT A LIVE READING",
            detail: "device.iso and device.exposureDuration are readable without a session, but with no session running they are the device's idle defaults, not what the sensor sees right now. Reported for completeness and explicitly flagged: do not treat these as an ambient-light measurement. A genuine reading needs a running AVCaptureSession with continuous auto-exposure settled, and then exposureTargetOffset / exposureTargetBias become the useful signals.",
            extra: [
                "iso": String(format: "%.3f", back.iso),
                "exposureDurationSeconds": String(format: "%.9f", CMTimeGetSeconds(back.exposureDuration)),
                "exposureTargetOffsetEV": String(format: "%.3f", back.exposureTargetOffset),
                "exposureTargetBiasEV": String(format: "%.3f", back.exposureTargetBias),
                "minExposureTargetBias": String(format: "%.3f", back.minExposureTargetBias),
                "maxExposureTargetBias": String(format: "%.3f", back.maxExposureTargetBias),
                "lensAperture": String(format: "%.3f", back.lensAperture),
                "isAdjustingExposure": AmbientProbeFmt.bool(back.isAdjustingExposure),
                "exposureMode": "\(back.exposureMode.rawValue)",
                "isTorchAvailable": AmbientProbeFmt.bool(back.isTorchAvailable),
                "sessionActive": "false",
                "isLiveMeasurement": "false"
            ]
        ))

        return items
    }
}

enum AmbientProbeCameraPosition {
    static func describe(_ p: AVCaptureDevice.Position) -> String {
        switch p {
        case .back: return "back"
        case .front: return "front"
        case .unspecified: return "unspecified"
        @unknown default: return "unknown(\(p.rawValue))"
        }
    }
}

enum AmbientProbeCameraDiscovery {
    /// Enumerating capture devices never prompts and never lights the camera
    /// indicator — it is a pure hardware query.
    static func devices(_ deviceTypes: [AVCaptureDevice.DeviceType]) -> [AVCaptureDevice] {
        // mediaType is nil, not .video: the LiDAR / TrueDepth cameras' primary
        // media type is depth data, and filtering on .video can silently drop
        // them from the inventory — which would read as "this phone has no
        // LiDAR". The typed local avoids a bare `nil` in the argument position.
        let mediaType: AVMediaType? = nil
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: mediaType,
            position: .unspecified
        ).devices
    }
}

// MARK: - 5. Barometric pressure cross-reference

extension AmbientProbe {

    func runPressureCrossReference() -> ProbeItem {
        ProbeItem(
            "ambient.pressure.crossref",
            "Barometric pressure (cross-reference)",
            .partial,
            value: "covered by MotionProbe — not duplicated here",
            detail: "Ambient pressure is the fourth classic environment signal after sound, light and temperature, and iOS exposes it via CMAltimeter (CMAltitudeData.pressure in kPa, plus relativeAltitude) with CMAltimeter.isRelativeAltitudeAvailable as the gate. It is probed in MotionProbe and is deliberately NOT repeated here: two probes starting altimeter updates in the same process would contend for the same sensor and produce two different answers for one device. Cross-reference only. Note that absolute pressure via CMAltimeter requires iOS 15+ CMAbsoluteAltitudeData, which MotionProbe owns.",
            extra: [
                "owner": "MotionProbe",
                "api": "CMAltimeter / CMAltitudeData.pressure",
                "unit": "kPa",
                "duplicatedHere": "false"
            ]
        )
    }
}

// MARK: - 6. Screen brightness as an ambient-light proxy

extension AmbientProbe {

    func runScreen() async -> [ProbeItem] {
        var items: [ProbeItem] = []

        let reading: AmbientProbeScreenReading = await MainActor.run {
            AmbientProbe.readScreen()
        }

        items.append(ProbeItem(
            "ambient.screen.brightness",
            "Screen brightness",
            reading.brightness >= 0 ? .ok : .unavailable,
            value: reading.brightness >= 0 ? String(format: "%.3f (0-1) — %.0f%%", reading.brightness, reading.brightness * 100) : "unreadable",
            detail: "The only ambient-light proxy on iOS that needs no permission, no session and no entitlement. With Auto-Brightness ON, this value tracks the true ambient light sensor with a lag and a user-offset baked in — a coarse but genuinely free lux signal. The catch, and it is a real one: there is NO public API to read whether Auto-Brightness is enabled (it lives in Settings > Accessibility > Display & Text Size, and UIAccessibility exposes no query for it). So a brightness value alone cannot be interpreted — 0.42 could be a dim room or a user who just dragged the slider. Sampled from \(reading.source).",
            extra: [
                "brightness": String(format: "%.4f", reading.brightness),
                "percent": String(format: "%.1f", reading.brightness * 100),
                "source": reading.source,
                "sampledAt": ProbeEnv.stamp(Date()) ?? "?",
                "autoBrightnessReadable": "false",
                "autoBrightnessAPI": "none — no public query exists",
                "screenCount": "\(reading.screenCount)",
                "maximumFramesPerSecond": "\(reading.maxFPS)",
                "nativeScale": String(format: "%.2f", reading.nativeScale),
                "nativeBounds": reading.nativeBounds,
                "isCaptured": AmbientProbeFmt.bool(reading.isCaptured),
                "traitUserInterfaceStyle": reading.userInterfaceStyle
            ]
        ))

        items.append(ProbeItem(
            "ambient.screen.brightnessNotification",
            "UIScreen.brightnessDidChangeNotification",
            reading.observerAttached ? .ok : .error,
            value: reading.observerAttached ? "observable — \(reading.notificationName)" : "could not attach observer",
            detail: "An observer was registered against NotificationCenter.default and immediately removed, proving the notification name resolves and is attachable. It was NOT proven to FIRE, and that is a deliberate choice: the only way to force a fire is to write UIScreen.brightness, and writing that property switches Auto-Brightness OFF persistently in the user's Settings. A probe must not degrade the device it is measuring. In a real collector this notification is the correct hook — it fires on both user slider moves and Auto-Brightness adjustments, giving a free, event-driven, permission-free ambient-light stream for as long as the app is foregrounded.",
            extra: [
                "notificationName": reading.notificationName,
                "observerAttached": AmbientProbeFmt.bool(reading.observerAttached),
                "firePathTested": "false",
                "firePathNotTestedBecause": "setting UIScreen.brightness disables Auto-Brightness persistently",
                "backgroundDelivery": "false — foreground only"
            ]
        ))

        return items
    }

    @MainActor
    static func readScreen() -> AmbientProbeScreenReading {
        var r = AmbientProbeScreenReading()

        // Prefer the scene-attached screen; UIScreen.main is soft-deprecated.
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        r.screenCount = UIScreen.screens.count
        let screen: UIScreen
        if let s = scenes.first {
            screen = s.screen
            r.source = "UIWindowScene.screen"
        } else {
            screen = UIScreen.main
            r.source = "UIScreen.main (no connected window scene)"
        }

        r.brightness = Double(screen.brightness)
        r.maxFPS = screen.maximumFramesPerSecond
        r.nativeScale = Double(screen.nativeScale)
        r.nativeBounds = "\(Int(screen.nativeBounds.width))x\(Int(screen.nativeBounds.height))"
        r.isCaptured = screen.isCaptured

        switch screen.traitCollection.userInterfaceStyle {
        case .dark: r.userInterfaceStyle = "dark"
        case .light: r.userInterfaceStyle = "light"
        case .unspecified: r.userInterfaceStyle = "unspecified"
        @unknown default: r.userInterfaceStyle = "unknown"
        }

        let name = UIScreen.brightnessDidChangeNotification
        r.notificationName = name.rawValue
        let token = NotificationCenter.default.addObserver(
            forName: name, object: nil, queue: nil) { _ in }
        NotificationCenter.default.removeObserver(token)
        r.observerAttached = true

        return r
    }
}

struct AmbientProbeScreenReading: Sendable {
    var brightness: Double = -1
    var source: String = "unknown"
    var screenCount: Int = 0
    var maxFPS: Int = 0
    var nativeScale: Double = 0
    var nativeBounds: String = "?"
    var isCaptured: Bool = false
    var userInterfaceStyle: String = "?"
    var notificationName: String = "?"
    var observerAttached: Bool = false
}

// MARK: - 7. Weather enrichment: WeatherKit vs Open-Meteo

extension AmbientProbe {

    func runWeather() -> [ProbeItem] {
        var items: [ProbeItem] = []

        #if canImport(WeatherKit)
        // Constructing the service is free; it is the first network call that
        // checks the entitlement and the paid-account JWT.
        let service = WeatherService()
        // Runtime check rather than a compile-time tautology: confirms the
        // concrete class actually instantiated inside the process.
        let constructed = String(describing: type(of: service)).contains("WeatherService")
        items.append(ProbeItem(
            "ambient.weatherkit.service",
            "WeatherKit availability",
            constructed ? .partial : .error,
            value: "canImport: true · WeatherService constructed: \(AmbientProbeFmt.bool(constructed)) · no request made",
            detail: "WeatherKit imports and WeatherService() constructs on a free/personal Apple ID — construction proves nothing. The gate is com.apple.developer.weatherkit, which requires a PAID Apple Developer Program membership and a service-registered App ID; without it the first weather(for:) call fails authentication server-side. No network request was made here, deliberately: firing one would need a CLLocation (LocationProbe's territory), would cost a round trip, and would return an auth error that tells us nothing the entitlement file does not already say. Status is .partial, not .ok — importable is not usable. Free tier when it IS provisioned: 500k calls/month, then metered.",
            extra: [
                "canImport": "true",
                "serviceConstructed": AmbientProbeFmt.bool(constructed),
                "serviceType": String(describing: type(of: service)),
                "entitlement": "com.apple.developer.weatherkit",
                "requiresPaidAccount": "true",
                "networkRequestMade": "false",
                "attributionRequired": "true — Apple Weather logo + legal link are mandatory",
                "freeTierCallsPerMonth": "500000"
            ]
        ))
        #else
        items.append(ProbeItem(
            "ambient.weatherkit.service",
            "WeatherKit availability",
            .unavailable,
            value: "canImport: false",
            detail: "canImport(WeatherKit) is false on this SDK, so the framework is not even linkable here."
        ))
        #endif

        items.append(ProbeItem(
            "ambient.weather.openMeteo",
            "Open-Meteo (free alternative)",
            .partial,
            value: "keyless, no entitlement, verified endpoint shape",
            detail: "The ownership-preserving substitute for WeatherKit: no API key, no account, no entitlement, no attribution requirement, CORS-open, ~10k calls/day for non-commercial use. Endpoint verified live on 2026-07-24 from this machine (not from the phone): GET https://api.open-meteo.com/v1/forecast?latitude=..&longitude=..&current=temperature_2m,relative_humidity_2m,surface_pressure,cloud_cover,wind_speed_10m — returns {latitude, longitude, elevation, current_units:{...}, current:{time, interval, temperature_2m, relative_humidity_2m, surface_pressure, cloud_cover, wind_speed_10m}}. No request was made from the device during this probe, so this item is .partial: the shape is confirmed, device reachability is not. surface_pressure in hPa is also the ground-truth cross-check for the CMAltimeter reading MotionProbe collects — an on-device barometer plus a free station pressure gives you calibrated altitude for nothing.",
            extra: [
                "baseURL": "https://api.open-meteo.com/v1/forecast",
                "apiKeyRequired": "false",
                "entitlementRequired": "false",
                "attributionRequired": "false",
                "freeTierCallsPerDay": "~10000 (non-commercial)",
                "currentFields": "temperature_2m,relative_humidity_2m,surface_pressure,cloud_cover,wind_speed_10m,apparent_temperature,precipitation,weather_code,wind_direction_10m",
                "historicalArchive": "https://archive-api.open-meteo.com/v1/archive (1940-present, free)",
                "airQuality": "https://air-quality-api.open-meteo.com/v1/air-quality (PM2.5, ozone, pollen — free)",
                "endpointVerified": "2026-07-24 (host machine, not device)",
                "requestMadeFromDevice": "false"
            ]
        ))

        return items
    }
}

// MARK: - 8. SensorKit

extension AmbientProbe {

    func runSensorKit() async -> [ProbeItem] {
        var items: [ProbeItem] = []

        #if canImport(SensorKit)

        // Only compile-time constants are referenced. Feeding doc-derived
        // strings into SRSensor(rawValue:) and then into SRSensorReader would
        // risk an ObjC exception inside the reader, and a trap in this probe
        // takes down all eleven sections, not just this one.
        let known: [(String, SRSensor)] = [
            ("ambientLightSensor", .ambientLightSensor),
            ("ambientPressure", .ambientPressure),
            ("accelerometer", .accelerometer),
            ("rotationRate", .rotationRate),
            ("pedometerData", .pedometerData),
            ("visits", .visits),
            ("deviceUsageReport", .deviceUsageReport),
            ("keyboardMetrics", .keyboardMetrics),
            ("messagesUsageReport", .messagesUsageReport),
            ("phoneUsageReport", .phoneUsageReport),
            ("onWristState", .onWristState),
            ("mediaEvents", .mediaEvents),
            ("odometer", .odometer),
            ("siriSpeechMetrics", .siriSpeechMetrics),
            ("telephonySpeechMetrics", .telephonySpeechMetrics),
            ("faceMetrics", .faceMetrics)
        ]

        // The raw strings are the finding. Probe-tier2.entitlements lists
        // hyphenated values ("ambient-light-sensor"); nothing in this project
        // has ever verified that those match SRSensor.rawValue. Now it does.
        var rawExtra: [String: String] = [
            "constantsReferenced": "\(known.count)",
            "enumerationMethod": "compile-time constants — SRSensor is a String-backed struct (NS_TYPED_ENUM) with no allCases and no runtime enumeration",
            "availabilityVerified": "faceMetrics=iOS17.0, odometer=iOS17.0, ambientPressure=iOS15.4, mediaEvents=iOS16.4 (checked against developer.apple.com 2026-07-24); the remainder are the original iOS 14.0 SensorKit set",
            "docListedButNotReferenced": "heartRate, wristTemperature, photoplethysmogram, electrocardiogram, sleepSessions, acousticSettings, headphoneMotion, headphoneSettings — listed in Apple's docs but their exact SDK availability could not be pinned down from here (several are marked Beta), and referencing a constant newer than the deployment target is a hard compile error, so they were omitted to protect the build for all eleven probes. Constructing them from doc-derived strings via SRSensor(rawValue:) was also rejected: an unrecognised sensor could raise inside SRSensorReader, and a trap here kills the entire report.",
            "deprecationNote": "SRSensorReader.requestAuthorization(sensors:completion:) is marked deprecated in iOS 27 in favour of SRReader<Sensor>; still current on the iOS 26 SDK this targets"
        ]
        for (name, s) in known {
            rawExtra["rawValue.\(name)"] = s.rawValue
        }
        let entitlementStrings = ["ambient-light-sensor", "accelerometer", "device-usage",
                                  "keyboard-metrics", "messages-usage", "phone-usage",
                                  "visits", "pedometer", "on-wrist"]
        rawExtra["entitlementFileStrings"] = entitlementStrings.joined(separator: ", ")
        let rawSet = Set(known.map { $0.1.rawValue })
        let matching = entitlementStrings.filter { rawSet.contains($0) }
        rawExtra["entitlementStringsMatchingSRSensorRawValues"] = matching.isEmpty ? "NONE" : matching.joined(separator: ", ")
        rawExtra["rawValuesEqualEntitlementStrings"] = matching.count == entitlementStrings.count ? "true" : "false"

        items.append(ProbeItem(
            "ambient.sensorkit.sensors",
            "SRSensor constants on this SDK",
            .ok,
            value: "\(known.count) constants referenced",
            detail: "SensorKit links and SRSensor resolves on a personal Apple ID — the framework is present, only the data is gated. Each constant's rawValue is recorded in extra so the hyphenated strings in Probe-tier2.entitlements can finally be checked against the SDK's own identifiers instead of being copied from a forum post.",
            extra: rawExtra
        ))

        // --- Per-sensor authorization status. Reading it is free and never prompts.
        let keySensors: [(String, SRSensor)] = [
            ("ambientLightSensor", .ambientLightSensor),
            ("ambientPressure", .ambientPressure),
            ("accelerometer", .accelerometer),
            ("deviceUsageReport", .deviceUsageReport),
            ("visits", .visits)
        ]
        var authExtra: [String: String] = [:]
        var anyAuthorized = false
        var allDenied = !keySensors.isEmpty
        var authPairs: [String] = []
        for (name, sensor) in keySensors {
            let reader = SRSensorReader(sensor: sensor)
            let st = AmbientProbeSensorKitAuth.describe(reader.authorizationStatus)
            authExtra["auth.\(name)"] = st
            authExtra["rawValue.\(name)"] = sensor.rawValue
            authPairs.append("\(name)=\(st)")
            if st == "authorized" { anyAuthorized = true }
            if st != "denied" { allDenied = false }
        }
        let authSectionStatus: ProbeStatus = anyAuthorized ? .ok : (allDenied ? .denied : .notDetermined)
        items.append(ProbeItem(
            "ambient.sensorkit.authorization",
            "SRSensorReader authorization status",
            authSectionStatus,
            value: authPairs.joined(separator: ", "),
            detail: "SRSensorReader(sensor:) constructs and .authorizationStatus reads without the entitlement — the object graph exists, it just never yields data. ambientLightSensor is the one that matters here: it is the ONLY public route to the real ambient light sensor behind the status bar (ARKit's lightEstimate is a camera-derived approximation, not the ALS).",
            extra: authExtra
        ))

        // --- Actually ask. The exact rejection is the ground truth we came for.
        let sensorSet: Set<SRSensor> = Set(keySensors.map { $0.1 })
        let requestOutcome: String = await AmbientProbeAwait.once(
            timeout: 10,
            timeoutValue: "TIMEOUT: requestAuthorization did not call back within 10s"
        ) { done in
            SRSensorReader.requestAuthorization(sensors: sensorSet) { error in
                if let error {
                    let ns = error as NSError
                    done("domain=\(ns.domain) code=\(ns.code) — \(ns.localizedDescription)")
                } else {
                    done("nil error — authorization sheet path succeeded")
                }
            }
        }

        let denied = requestOutcome.lowercased().contains("entitle")
            || requestOutcome.contains("code=8")
            || requestOutcome.lowercased().contains("denied")
            || requestOutcome.hasPrefix("TIMEOUT")

        var postAuth: [String: String] = ["requestOutcome": requestOutcome]
        for (name, sensor) in keySensors {
            let reader = SRSensorReader(sensor: sensor)
            postAuth["authAfterRequest.\(name)"] = AmbientProbeSensorKitAuth.describe(reader.authorizationStatus)
        }
        postAuth["sensorsRequested"] = keySensors.map { $0.0 }.joined(separator: ", ")

        items.append(ProbeItem(
            "ambient.sensorkit.requestAuthorization",
            "SRSensorReader.requestAuthorization result",
            denied ? .denied : .partial,
            value: requestOutcome,
            detail: "The exact rejection, captured verbatim rather than assumed. On the access question — SOURCED, per Apple's developer documentation and researchandcare.org (checked 2026-07-24): com.apple.developer.sensorkit.reader.allow is granted per STUDY, not per developer. A development entitlement requires an approved research proposal; the distribution entitlement additionally requires an IRB / Ethics Committee approval letter plus a SensorKit Addendum signed through an INSTITUTIONAL Apple Developer account, and the grant is scoped to one study and one app. Apple documents no individual, non-research path, so the practical answer for this project is no. UNVERIFIED PREDICTION, stated as such: because entitlement grants are recorded against the developer account, the Tier-2 provisioning profile is expected to fail to build rather than to build and fail at runtime. That prediction is exactly what Probe-tier2.entitlements exists to settle — record the actual toolchain error when it is attempted and replace this sentence with the observed result. Plan around SensorKit, not for it.",
            extra: postAuth
        ))

        #else
        items.append(ProbeItem(
            "ambient.sensorkit.sensors",
            "SensorKit",
            .unavailable,
            value: "canImport(SensorKit) == false",
            detail: "SensorKit is not importable on this SDK. Even where it is, com.apple.developer.sensorkit.reader.allow is granted per approved research study with IRB approval via an institutional developer account — never to an individual."
        ))
        #endif

        return items
    }
}

#if canImport(SensorKit)
enum AmbientProbeSensorKitAuth {
    static func describe(_ s: SRAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: return "notDetermined"
        case .authorized: return "authorized"
        case .denied: return "denied"
        @unknown default: return "unknown(\(s.rawValue))"
        }
    }
}
#endif

// MARK: - Section summary

enum AmbientProbeSummary {
    static func build(_ items: [ProbeItem]) -> String {
        func val(_ key: String) -> String? { items.first(where: { $0.key == key })?.value }
        func status(_ key: String) -> ProbeStatus? { items.first(where: { $0.key == key })?.status }

        var parts: [String] = []

        if let mic = val("ambient.mic.level"), status("ambient.mic.level") == .ok {
            parts.append("Room: \(mic).")
        } else if let s = status("ambient.mic.permission"), s == .denied {
            parts.append("Mic denied — no sound level.")
        } else {
            parts.append("Mic level unavailable.")
        }

        if let input = val("ambient.audio.currentInput") {
            parts.append("Input \(input).")
        }
        if let out = val("ambient.audio.outputRoute") {
            parts.append("Output \(out).")
        }
        if let cls = val("ambient.soundanalysis.classifier") {
            parts.append("Sound classifier: \(cls) (no permission, no download).")
        }
        if let ar = val("ambient.arkit.support") {
            parts.append("ARKit \(ar); lightEstimate reachable but needs a live foreground camera session, so it was not sampled.")
        }
        if let cam = val("ambient.camera.backFormat") {
            parts.append("Back camera envelope readable with no session and no permission — \(cam).")
        }
        if let br = val("ambient.screen.brightness") {
            parts.append("Screen brightness \(br) — a free lux proxy, but iOS exposes no way to read whether Auto-Brightness is on, so it is uninterpretable alone.")
        }

        parts.append("Barometric pressure is CMAltimeter and belongs to MotionProbe — cross-referenced, not duplicated.")
        parts.append("WeatherKit imports and constructs but needs com.apple.developer.weatherkit and a paid account; Open-Meteo (api.open-meteo.com/v1/forecast) is the free, keyless, no-entitlement, no-attribution substitute and its surface_pressure field also calibrates the on-device barometer.")
        parts.append("SensorKit links and SRSensorReader resolves; the data does not. Apple's documented process routes com.apple.developer.sensorkit.reader.allow through per-study approval requiring an IRB letter and an institutional developer account, and documents no individual path — so treat it as unobtainable here. Whether Tier-2 fails at provisioning or at runtime is an open prediction this project will settle, not a verified fact.")

        return parts.joined(separator: " ")
    }
}
