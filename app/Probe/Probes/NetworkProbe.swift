import Foundation
import Darwin
import Network
import CoreTelephony
import CoreBluetooth
import CryptoKit
import AVFoundation
#if canImport(NetworkExtension)
import NetworkExtension
#endif

// MARK: - NetworkProbe
//
// Ground truth for the radio/network stack on one specific iPhone.
//
// What this file learned by reading the actual iOS SDK headers rather than the
// rendered documentation (the two disagree in three places that matter):
//
//  1. CoreTelephony/CTTelephonyNetworkInfo.h  — `serviceCurrentRadioAccessTechnology`
//     is API_AVAILABLE(ios(12.0)) and is NOT deprecated. It is the only part of
//     CoreTelephony still worth reading. `serviceSubscriberCellularProviders` is
//     API_DEPRECATED("Deprecated with no replacement", ios(12.0, 16.0)) and since
//     iOS 16.4 the CTCarrier objects it hands back are hollow placeholders.
//
//  2. NetworkExtension/NEHotspotNetwork.h — the PUBLIC class declares exactly four
//     members: SSID, BSSID, securityType (ios 15.0+), and
//     +fetchCurrentWithCompletionHandler: (ios 14.0+). `signalStrength`,
//     `isSecure`, `didAutoJoin`, `didJustJoin` live in a *different* header
//     (NEHotspotHelper.h) as a category gated on the Apple-approved
//     com.apple.developer.networking.HotspotHelper entitlement. This probe does
//     not touch that category — see the `network.wifi.signalStrength` item.
//
//  3. net/route.h has never shipped in the iOS *device* SDK (simulator only), so
//     sysctl NET_RT_IFLIST2 / if_msghdr2 / if_data64 — the 64-bit, non-wrapping
//     byte counters everyone uses on macOS — cannot even be compiled here. The
//     32-bit `if_data` from getifaddrs(3) is the only byte counter iOS exposes.
//
// Nothing in this file is private API. Everything is public headers only.

struct NetworkProbe: TelemetryProbe {
    let key = "network"
    let title = "Network & Radio"

    func run() async -> ProbeSection {
        var items: [ProbeItem] = []

        items.append(contentsOf: await NetworkProbeWork.pathItems())
        items.append(contentsOf: NetworkProbeWork.telephonyItems())
        items.append(contentsOf: await NetworkProbeWork.hotspotItems())
        items.append(contentsOf: await NetworkProbeWork.counterItems())
        items.append(contentsOf: await NetworkProbeWork.bluetoothItems())
        items.append(contentsOf: NetworkProbeWork.audioRouteItems())
        items.append(contentsOf: NetworkProbeWork.localNetworkItems())
        items.append(contentsOf: NetworkProbeWork.macItems())

        return section(NetworkProbeSummary.text(items), items)
    }
}

// MARK: - Small shared primitives (all NetworkProbe-prefixed)

/// Guarantees a continuation is resumed exactly once even though the underlying
/// delegate/callback can fire zero times, once, or many times.
final class NetworkProbeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    /// Returns true exactly once, for the first caller.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

/// Normalises an SDK property whose optionality we do not want to hard-code.
/// A non-optional `String` promotes to `T?`; an optional `String?` infers `T = String`.
/// Either way the call site compiles, which matters for ObjC-imported properties
/// whose nullability annotations change between SDK versions.
enum NetworkProbeOpt {
    static func of<T>(_ v: T?) -> T? { v }
}

/// Stable, salted SHA-256 tag used for anything that names a place or a person's
/// hardware (SSID, BSSID, BLE peripheral UUID, audio port name).
///
/// The salt is a fixed compile-time constant, NOT random per run. That is
/// deliberate: a random salt would make every report's hashes mutually
/// incomparable and destroy the entire point. With a constant salt the same
/// Wi-Fi network produces the same tag in every report, forever, on every
/// device — which is exactly what turns it into a usable place fingerprint.
enum NetworkProbeHash {
    static let salt = "ios-telemetry-probe/network/v1|"
    static let algoNote = "SHA-256(constantSalt || value), first 48 bits, lowercase hex"

    static func tag(_ value: String, _ prefix: String) -> String {
        guard let data = (salt + value).data(using: .utf8) else { return "\(prefix):encoding-failed" }
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "\(prefix):\(String(hex.prefix(12)))"
    }
}

enum NetworkProbeFmt {
    /// 1_234_567 -> "1.18 MB" (binary), plus the raw grouped integer.
    static func bytes(_ v: UInt64) -> String {
        let d = Double(v)
        let units = ["B", "KB", "MB", "GB", "TB"]
        var idx = 0
        var scaled = d
        while scaled >= 1024, idx < units.count - 1 {
            scaled /= 1024
            idx += 1
        }
        let unit = idx < units.count ? units[idx] : "B"
        return "\(ProbeEnv.num(scaled)) \(unit)"
    }

}

// MARK: - Network path (NWPathMonitor)

struct NetworkProbePathSnapshot: Sendable {
    var status: String
    var unsatisfiedReason: String
    var isExpensive: Bool
    var isConstrained: Bool
    var supportsIPv4: Bool
    var supportsIPv6: Bool
    var supportsDNS: Bool
    var gatewayCount: Int
    /// Ordered exactly as NWPath.availableInterfaces returns them — the order IS
    /// the routing preference, which is why we keep it rather than sorting.
    var interfaces: [String]
    var usesWiFi: Bool
    var usesCellular: Bool
    var usesWired: Bool
    var usesLoopback: Bool
    var usesOther: Bool

    // MUST be qualified. NetworkExtension also exports a (deprecated) `NWPath`
    // class, so with both frameworks imported the bare name is ambiguous and
    // every `.wifi` / `.cellular` member lookup below fails to infer its base.
    init(_ p: Network.NWPath) {
        status = String(describing: p.status)
        // String(describing:) rather than a switch: NWPath.UnsatisfiedReason has
        // grown cases in 14.2, 16 and 17, and a switch would either warn or go
        // stale. The mirror gives the real case name on whatever SDK is current.
        // (Property is iOS 14.2+; the 17.0 deployment target covers it.)
        unsatisfiedReason = String(describing: p.unsatisfiedReason)
        isExpensive = p.isExpensive
        isConstrained = p.isConstrained
        supportsIPv4 = p.supportsIPv4
        supportsIPv6 = p.supportsIPv6
        supportsDNS = p.supportsDNS
        gatewayCount = p.gateways.count
        interfaces = p.availableInterfaces.map { "\($0.name) (\(String(describing: $0.type)))" }
        usesWiFi = p.usesInterfaceType(.wifi)
        usesCellular = p.usesInterfaceType(.cellular)
        usesWired = p.usesInterfaceType(.wiredEthernet)
        usesLoopback = p.usesInterfaceType(.loopback)
        usesOther = p.usesInterfaceType(.other)
    }
}

enum NetworkProbePath {
    /// Starts a monitor, waits for the first path callback (or a hard deadline),
    /// then cancels. The deadline resume is scheduled on the monitor's own queue
    /// so the continuation is resumed exactly once on every path, including the
    /// case where the callback never arrives at all.
    static func snapshot(requiring type: NWInterface.InterfaceType?,
                         timeout: Double) async -> NetworkProbePathSnapshot? {
        let monitor: NWPathMonitor
        if let type {
            monitor = NWPathMonitor(requiredInterfaceType: type)
        } else {
            monitor = NWPathMonitor()
        }
        let queue = DispatchQueue(label: "probe.network.path.\(type.map { String(describing: $0) } ?? "any")")
        let once = NetworkProbeOnce()

        let snap: NetworkProbePathSnapshot? = await withCheckedContinuation { c in
            monitor.pathUpdateHandler = { path in
                guard once.claim() else { return }
                c.resume(returning: NetworkProbePathSnapshot(path))
            }
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                guard once.claim() else { return }
                c.resume(returning: nil)
            }
        }

        // Teardown lives OUTSIDE the continuation so it runs on the timeout path too.
        monitor.pathUpdateHandler = nil
        monitor.cancel()
        return snap
    }
}

// MARK: - Cellular radio (CoreTelephony)

enum NetworkProbeRadio {
    /// Raw constant -> (human label, generation, rough real-world downlink ceiling).
    /// Reported alongside the RAW constant, never instead of it — the constant is
    /// the thing a future collector keys on.
    static func describe(_ raw: String) -> (label: String, generation: String, ceiling: String) {
        switch raw {
        case CTRadioAccessTechnologyGPRS:         return ("GPRS", "2G", "~0.1 Mbps")
        case CTRadioAccessTechnologyEdge:         return ("EDGE", "2.5G", "~0.4 Mbps")
        case CTRadioAccessTechnologyWCDMA:        return ("WCDMA / UMTS", "3G", "~2 Mbps")
        case CTRadioAccessTechnologyHSDPA:        return ("HSDPA", "3.5G", "~14 Mbps")
        case CTRadioAccessTechnologyHSUPA:        return ("HSUPA", "3.5G", "~5.7 Mbps up")
        case CTRadioAccessTechnologyCDMA1x:       return ("CDMA 1x", "2G", "~0.15 Mbps")
        case CTRadioAccessTechnologyCDMAEVDORev0: return ("EVDO Rev 0", "3G", "~2.4 Mbps")
        case CTRadioAccessTechnologyCDMAEVDORevA: return ("EVDO Rev A", "3G", "~3.1 Mbps")
        case CTRadioAccessTechnologyCDMAEVDORevB: return ("EVDO Rev B", "3G", "~14 Mbps")
        case CTRadioAccessTechnologyeHRPD:        return ("eHRPD", "3G", "~14 Mbps")
        case CTRadioAccessTechnologyLTE:          return ("LTE", "4G", "~50-150 Mbps")
        case CTRadioAccessTechnologyNRNSA:        return ("NR non-standalone (5G anchored on LTE)", "5G NSA", "~100-800 Mbps")
        case CTRadioAccessTechnologyNR:           return ("NR standalone", "5G SA", "~100-800 Mbps")
        default:                                  return ("unrecognised constant", "unknown", "unknown")
        }
    }

    /// Names of the constants themselves, so the report records which vocabulary
    /// this SDK actually shipped rather than which one we assumed.
    static let knownConstants: [String] = [
        CTRadioAccessTechnologyGPRS, CTRadioAccessTechnologyEdge,
        CTRadioAccessTechnologyWCDMA, CTRadioAccessTechnologyHSDPA,
        CTRadioAccessTechnologyHSUPA, CTRadioAccessTechnologyCDMA1x,
        CTRadioAccessTechnologyCDMAEVDORev0, CTRadioAccessTechnologyCDMAEVDORevA,
        CTRadioAccessTechnologyCDMAEVDORevB, CTRadioAccessTechnologyeHRPD,
        CTRadioAccessTechnologyLTE, CTRadioAccessTechnologyNRNSA,
        CTRadioAccessTechnologyNR
    ]

    /// iOS 16.4+ replaces every CTCarrier string field with a placeholder.
    static func isHollow(_ s: String?) -> Bool {
        guard let s else { return true }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t == "--" || t == "65535"
    }
}

// MARK: - Wi-Fi (NEHotspotNetwork)

enum NetworkProbeHotspotResult {
    case found(ssidTag: String, bssidTag: String, oui: String?, securityRaw: Int?)
    case nilResult
    case timedOut
    case frameworkMissing
}

enum NetworkProbeHotspot {
    static let securityLabels: [Int: String] = [
        0: "Open — no link-layer encryption",
        1: "WEP — broken, effectively open",
        2: "Personal — WPA/WPA2/WPA3 pre-shared key",
        3: "Enterprise — WPA/WPA2/WPA3 802.1X",
        4: "Unknown"
    ]

    static func fetch(timeout: Double) async -> NetworkProbeHotspotResult {
        #if canImport(NetworkExtension)
        let queue = DispatchQueue(label: "probe.network.hotspot")
        let once = NetworkProbeOnce()
        return await withCheckedContinuation { (c: CheckedContinuation<NetworkProbeHotspotResult, Never>) in
            // Known failure mode (Apple DTS forum 670970): without the entitlement
            // the completion handler has been reported to never fire at all on
            // some builds, so a deadline resume is mandatory, not decorative.
            NEHotspotNetwork.fetchCurrent { net in
                guard once.claim() else { return }
                guard let net else {
                    c.resume(returning: .nilResult)
                    return
                }
                let ssid = NetworkProbeOpt.of(net.ssid) ?? ""
                let bssid = NetworkProbeOpt.of(net.bssid) ?? ""
                // securityType is API_AVAILABLE(ios(15.0)); the 17.0 deployment
                // target covers it, so no availability guard is needed.
                let sec: Int? = net.securityType.rawValue
                // The OUI (first three octets of the BSSID) names the access
                // point's silicon vendor, not the household. It is useful and
                // non-identifying, so it is reported in the clear.
                var oui: String? = nil
                let parts = bssid.split(separator: ":")
                if parts.count >= 3 {
                    oui = parts.prefix(3).joined(separator: ":").uppercased()
                }
                c.resume(returning: .found(
                    ssidTag: ssid.isEmpty ? "ssid:empty" : NetworkProbeHash.tag(ssid, "ssid"),
                    bssidTag: bssid.isEmpty ? "bssid:empty" : NetworkProbeHash.tag(bssid, "bssid"),
                    oui: oui,
                    securityRaw: sec))
            }
            queue.asyncAfter(deadline: .now() + timeout) {
                guard once.claim() else { return }
                c.resume(returning: .timedOut)
            }
        }
        #else
        return .frameworkMissing
        #endif
    }
}

// MARK: - Per-interface byte counters (getifaddrs)

struct NetworkProbeIfStat {
    var name: String
    var inBytes: UInt64 = 0
    var outBytes: UInt64 = 0
    var inPackets: UInt64 = 0
    var outPackets: UInt64 = 0
    var inErrors: UInt64 = 0
    var outErrors: UInt64 = 0
    var linkAddress: String?

    var isWiFiClass: Bool { name.hasPrefix("en") }
    var isCellular: Bool { name.hasPrefix("pdp_ip") }
    var isVPN: Bool { name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") || name.hasPrefix("tap") }
    var isAWDL: Bool { name.hasPrefix("awdl") || name.hasPrefix("llw") }
    var isHotspotAP: Bool { name.hasPrefix("ap") }
    var isLoopback: Bool { name.hasPrefix("lo") }
    var total: UInt64 { inBytes &+ outBytes }
}

struct NetworkProbeIfSample {
    var stats: [NetworkProbeIfStat]
    /// Measured, not assumed: sizeof(if_data.ifi_ibytes) on THIS SDK. 4 => the
    /// counters are modulo 2^32 and have almost certainly wrapped.
    var byteFieldWidth: Int
    var takenAt: Date

    func named(_ n: String) -> NetworkProbeIfStat? { stats.first { $0.name == n } }
    func sum(_ pick: (NetworkProbeIfStat) -> Bool) -> (inB: UInt64, outB: UInt64) {
        var i: UInt64 = 0
        var o: UInt64 = 0
        for s in stats where pick(s) {
            i = i &+ s.inBytes
            o = o &+ s.outBytes
        }
        return (i, o)
    }
}

enum NetworkProbeIfCounters {
    static func read() -> NetworkProbeIfSample? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }

        var out: [NetworkProbeIfStat] = []
        var width = 0
        var cursor = head

        while let node = cursor {
            defer { cursor = node.pointee.ifa_next }
            guard let namePtr = node.pointee.ifa_name else { continue }
            guard let addrPtr = node.pointee.ifa_addr else { continue }
            // Byte counters hang off the AF_LINK (link-layer) entry only. The
            // AF_INET / AF_INET6 entries for the same interface carry addresses
            // and a NULL ifa_data — reading those is the classic zero-bytes bug.
            guard addrPtr.pointee.sa_family == UInt8(AF_LINK) else { continue }

            var stat = NetworkProbeIfStat(name: String(cString: namePtr))

            if let dataPtr = node.pointee.ifa_data {
                let d = dataPtr.assumingMemoryBound(to: if_data.self)
                width = MemoryLayout.size(ofValue: d.pointee.ifi_ibytes)
                stat.inBytes = UInt64(d.pointee.ifi_ibytes)
                stat.outBytes = UInt64(d.pointee.ifi_obytes)
                stat.inPackets = UInt64(d.pointee.ifi_ipackets)
                stat.outPackets = UInt64(d.pointee.ifi_opackets)
                stat.inErrors = UInt64(d.pointee.ifi_ierrors)
                stat.outErrors = UInt64(d.pointee.ifi_oerrors)
            }

            stat.linkAddress = linkAddress(addrPtr)
            out.append(stat)
        }

        return NetworkProbeIfSample(stats: out, byteFieldWidth: width, takenAt: Date())
    }

    /// Pulls the hardware address out of the sockaddr_dl. Bounds-checked against
    /// the 12-byte sdl_data tuple so a malformed entry cannot read past the end.
    static func linkAddress(_ sa: UnsafeMutablePointer<sockaddr>) -> String? {
        sa.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dl -> String? in
            let nlen = Int(dl.pointee.sdl_nlen)
            let alen = Int(dl.pointee.sdl_alen)
            guard alen > 0, nlen >= 0 else { return nil }
            var bytes: [UInt8] = []
            withUnsafeBytes(of: dl.pointee.sdl_data) { raw in
                var i = 0
                while i < alen {
                    let idx = nlen + i
                    if idx >= 0 && idx < raw.count { bytes.append(raw[idx]) }
                    i += 1
                }
            }
            guard bytes.count == alen else { return nil }
            return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
        }
    }
}

// MARK: - Bluetooth LE scan (CoreBluetooth)

struct NetworkProbeBTResult {
    var state: String = "unknown"
    var reachedPoweredOn = false
    var distinct: [(tag: String, rssi: Int)] = []
    var connectableAds = 0
    var serviceUUIDAds = 0
    var localNameAds = 0
    var manufacturerAds = 0
    var companyIDs: Set<UInt16> = []
    var scanSeconds: Double = 0
}

final class NetworkProbeBTScanner: NSObject, CBCentralManagerDelegate {
    let queue = DispatchQueue(label: "probe.network.bt")
    private let lock = NSLock()

    private var manager: CBCentralManager?
    private var stateCont: CheckedContinuation<CBManagerState, Never>?
    private var pendingState: CBManagerState?
    private var resolved = false

    private var rssiByPeripheral: [UUID: Int] = [:]
    private var connectableAds = 0
    private var serviceUUIDAds = 0
    private var localNameAds = 0
    private var manufacturerAds = 0
    private var companyIDs: Set<UInt16> = []

    /// Creates the central manager and waits for it to leave `.unknown`.
    /// Resolves exactly once: via the delegate, via an already-known state, or
    /// via the deadline.
    func startAndWaitForState(timeout: Double) async -> CBManagerState {
        await withCheckedContinuation { (c: CheckedContinuation<CBManagerState, Never>) in
            var immediate: CBManagerState?
            self.lock.lock()
            if let p = self.pendingState, !self.resolved {
                self.resolved = true
                immediate = p
            } else if !self.resolved {
                self.stateCont = c
            }
            self.lock.unlock()

            if let immediate {
                c.resume(returning: immediate)
                return
            }

            // showPowerAlert:false — we want to *observe* a powered-off radio, not
            // pop a modal at the user in the middle of an automated report run.
            let m = CBCentralManager(delegate: self,
                                     queue: self.queue,
                                     options: [CBCentralManagerOptionShowPowerAlertKey: false])
            self.lock.lock()
            self.manager = m
            self.lock.unlock()

            self.queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.deliver(m.state)
            }
        }
    }

    private func deliver(_ s: CBManagerState) {
        var toResume: CheckedContinuation<CBManagerState, Never>?
        lock.lock()
        if resolved {
            lock.unlock()
            return
        }
        if let c = stateCont {
            resolved = true
            stateCont = nil
            toResume = c
        } else {
            pendingState = s
        }
        lock.unlock()
        toResume?.resume(returning: s)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // Fires repeatedly across the app's life; `deliver` is idempotent.
        guard central.state != .unknown else { return }
        deliver(central.state)
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        lock.lock()
        defer { lock.unlock() }
        rssiByPeripheral[peripheral.identifier] = RSSI.intValue
        if let n = advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber, n.boolValue {
            connectableAds += 1
        }
        if let uuids = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID], !uuids.isEmpty {
            serviceUUIDAds += 1
        }
        if advertisementData[CBAdvertisementDataLocalNameKey] != nil {
            localNameAds += 1
        }
        if let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, mfg.count >= 2 {
            manufacturerAds += 1
            let lo = UInt16(mfg[mfg.startIndex])
            let hi = UInt16(mfg[mfg.startIndex + 1])
            companyIDs.insert(lo | (hi << 8))   // Bluetooth SIG company ID, little-endian
        }
    }

    /// Passive scan. `allowDuplicates: false` means one callback per peripheral
    /// per scan session, which is what makes the resulting count a crowd proxy
    /// rather than an advertisement-rate proxy.
    func scan(seconds: Double) async {
        lock.lock()
        let m = manager
        lock.unlock()
        guard let m else { return }
        m.scanForPeripherals(withServices: nil,
                             options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        m.stopScan()
    }

    func snapshot() -> NetworkProbeBTResult {
        lock.lock()
        defer { lock.unlock() }
        var r = NetworkProbeBTResult()
        r.distinct = rssiByPeripheral
            .map { (tag: NetworkProbeHash.tag($0.key.uuidString, "ble"), rssi: $0.value) }
            .sorted { $0.rssi > $1.rssi }
        r.connectableAds = connectableAds
        r.serviceUUIDAds = serviceUUIDAds
        r.localNameAds = localNameAds
        r.manufacturerAds = manufacturerAds
        r.companyIDs = companyIDs
        return r
    }

    /// Unconditional teardown — safe to call on every exit path, including timeout.
    func shutdown() {
        lock.lock()
        let m = manager
        manager = nil
        lock.unlock()
        m?.stopScan()
        m?.delegate = nil
    }
}

enum NetworkProbeBT {
    static func stateName(_ s: CBManagerState) -> String {
        switch s {
        case .unknown: return "unknown"
        case .resetting: return "resetting"
        case .unsupported: return "unsupported"
        case .unauthorized: return "unauthorized"
        case .poweredOff: return "poweredOff"
        case .poweredOn: return "poweredOn"
        @unknown default: return "unrecognised(\(s.rawValue))"
        }
    }

    static func authName(_ a: CBManagerAuthorization) -> String {
        switch a {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .allowedAlways: return "allowedAlways"
        @unknown default: return "unrecognised(\(a.rawValue))"
        }
    }

    static func authStatus(_ a: CBManagerAuthorization) -> ProbeStatus {
        switch a {
        case .allowedAlways: return .ok
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .partial
        }
    }

    /// Assigned Bluetooth SIG company identifiers worth naming. Everything else
    /// is reported as a hex ID, which is still a device-mix signal.
    static let companyNames: [UInt16: String] = [
        0x004C: "Apple",
        0x0006: "Microsoft",
        0x00E0: "Google",
        0x0075: "Samsung",
        0x0087: "Garmin",
        0x000F: "Broadcom",
        0x0059: "Nordic Semiconductor",
        0x0157: "Anhui Huami (Amazfit)",
        0x038F: "Xiaomi",
        0x0171: "Amazon",
        0x0499: "Ruuvi",
        0x0118: "Tile",
        0x02E5: "Espressif",
        0x0030: "ST Microelectronics",
        0x004F: "APT / Qualcomm",
        0x0001: "Ericsson"
    ]

    static func bucket(_ rssi: Int) -> String {
        switch rssi {
        case (-50)...0:     return "≥ -50 dBm (same table / arm's length)"
        case (-70)...(-51): return "-51..-70 dBm (same room)"
        case (-85)...(-71): return "-71..-85 dBm (adjacent room / across an office)"
        default:            return "< -85 dBm (edge of range)"
        }
    }
}

// MARK: - Work

enum NetworkProbeWork {

    // 1 ------------------------------------------------------------- NWPath

    static func pathItems() async -> [ProbeItem] {
        var items: [ProbeItem] = []

        let defaultPath = await NetworkProbePath.snapshot(requiring: nil, timeout: 2.5)

        guard let p = defaultPath else {
            items.append(ProbeItem("network.path.current", "Current network path", .error,
                                   detail: "NWPathMonitor produced no path callback within 2.5s. The monitor was started and cancelled cleanly; this is a framework stall, not a permission problem."))
            return items
        }

        var extra: [String: String] = [
            "status": p.status,
            "unsatisfiedReason": p.unsatisfiedReason,
            "isExpensive": String(p.isExpensive),
            "isConstrained": String(p.isConstrained),
            "supportsIPv4": String(p.supportsIPv4),
            "supportsIPv6": String(p.supportsIPv6),
            "supportsDNS": String(p.supportsDNS),
            "gatewayCount": String(p.gatewayCount),
            "availableInterfaceCount": String(p.interfaces.count),
            "usesWiFi": String(p.usesWiFi),
            "usesCellular": String(p.usesCellular),
            "usesWiredEthernet": String(p.usesWired),
            "usesLoopback": String(p.usesLoopback),
            "usesOther": String(p.usesOther)
        ]
        for (i, name) in p.interfaces.enumerated() {
            extra["interface[\(i)]"] = name
        }

        let primary: String
        if p.usesWiFi { primary = "Wi-Fi" }
        else if p.usesCellular { primary = "Cellular" }
        else if p.usesWired { primary = "Wired Ethernet" }
        else if p.usesLoopback { primary = "Loopback only" }
        else { primary = "none" }

        items.append(ProbeItem(
            "network.path.current", "Current network path",
            p.status == "satisfied" ? .ok : .partial,
            value: "\(p.status) — primary \(primary), \(p.interfaces.count) interface(s)",
            detail: """
            NWPath.availableInterfaces is returned in ROUTING PREFERENCE ORDER, not \
            alphabetical order — index 0 is the interface the system will actually use. \
            That ordering is the most useful part of this item and is preserved verbatim in \
            `extra`. `isExpensive` is true on cellular and on Personal Hotspot; \
            `isConstrained` is true only when the user has switched on Low Data Mode for \
            this specific interface, so the two are independent flags, not a scale. \
            unsatisfiedReason is read via reflection rather than a switch because the enum \
            gained cases in iOS 14.2, 16 and 17 and a hard-coded switch would go stale \
            silently.
            """,
            extra: extra))

        // Typed monitors answer a different question from usesInterfaceType():
        // "could a connection *restricted* to this interface be satisfied right
        // now" — i.e. is the radio actually usable, not merely present.
        let wifiOnly = await NetworkProbePath.snapshot(requiring: .wifi, timeout: 2.0)
        let cellOnly = await NetworkProbePath.snapshot(requiring: .cellular, timeout: 2.0)

        items.append(ProbeItem(
            "network.path.wifiOnly", "Wi-Fi-restricted path satisfiable",
            typedPathStatus(wifiOnly),
            value: typedPathValue(wifiOnly),
            detail: "NWPathMonitor(requiredInterfaceType: .wifi). Distinct from path.usesInterfaceType(.wifi): this asks whether a connection pinned to Wi-Fi would succeed right now, which is how you detect an associated-but-dead AP (captive portal, no DHCP lease).",
            extra: wifiOnly.map { ["supportsIPv6": String($0.supportsIPv6), "isConstrained": String($0.isConstrained), "gatewayCount": String($0.gatewayCount)] }))

        items.append(ProbeItem(
            "network.path.cellularOnly", "Cellular-restricted path satisfiable",
            typedPathStatus(cellOnly),
            value: typedPathValue(cellOnly),
            detail: "NWPathMonitor(requiredInterfaceType: .cellular). `cellularDenied` here means the user turned this app's cellular data off in Settings > Cellular, which is a per-app switch invisible to every other API.",
            extra: cellOnly.map { ["supportsIPv6": String($0.supportsIPv6), "isExpensive": String($0.isExpensive), "isConstrained": String($0.isConstrained)] }))

        return items
    }

    private static func typedPathStatus(_ s: NetworkProbePathSnapshot?) -> ProbeStatus {
        guard let s else { return .error }
        return s.status == "satisfied" ? .ok : .empty
    }

    private static func typedPathValue(_ s: NetworkProbePathSnapshot?) -> String {
        guard let s else { return "no path callback within the 2.0s deadline" }
        if s.status == "satisfied" { return "satisfied" }
        return s.status + " — " + s.unsatisfiedReason
    }

    // 2 -------------------------------------------------------- CoreTelephony

    static func telephonyItems() -> [ProbeItem] {
        var items: [ProbeItem] = []

        // Held strongly for the whole read: a CTTelephonyNetworkInfo that is
        // released too early is a documented source of nil dictionaries.
        let info = CTTelephonyNetworkInfo()

        // --- radio access technology (NOT deprecated; this is the live one)
        let rats = info.serviceCurrentRadioAccessTechnology
        if let rats, !rats.isEmpty {
            var extra: [String: String] = ["serviceCount": String(rats.count)]
            var lines: [String] = []
            for (service, raw) in rats.sorted(by: { $0.key < $1.key }) {
                let d = NetworkProbeRadio.describe(raw)
                // The service key is an opaque CoreTelephony service UUID; hash it
                // so two reports from the same phone line up without publishing it.
                let svc = NetworkProbeHash.tag(service, "svc")
                extra["\(svc).rawConstant"] = raw
                extra["\(svc).label"] = d.label
                extra["\(svc).generation"] = d.generation
                extra["\(svc).typicalDownlink"] = d.ceiling
                lines.append("\(svc) = \(raw) (\(d.generation))")
            }
            if let dsi = info.dataServiceIdentifier {
                extra["dataServiceIdentifier"] = NetworkProbeHash.tag(dsi, "svc")
            }
            items.append(ProbeItem(
                "network.radio.accessTechnology", "Radio access technology (per service)", .ok,
                value: lines.joined(separator: " · "),
                detail: """
                Raw constant reported verbatim — that string, not a prettified label, is what \
                a collector should store. CTRadioAccessTechnologyNRNSA means 5G riding on an \
                LTE anchor (the common "5G" case); CTRadioAccessTechnologyNR means true \
                standalone 5G. Both constants arrived in iOS 14.1. This property is the ONLY \
                part of CoreTelephony that is still alive: the header marks it \
                API_AVAILABLE(ios(12.0)) with no deprecation, while every carrier-identity \
                property beside it is API_DEPRECATED since iOS 16.0. Multiple keys means \
                dual-SIM / eSIM; dataServiceIdentifier says which one is carrying data.
                """,
                extra: extra))
        } else {
            items.append(ProbeItem(
                "network.radio.accessTechnology", "Radio access technology (per service)", .empty,
                value: rats == nil ? "nil dictionary" : "empty dictionary",
                detail: "No service is registered on a cellular network right now (airplane mode, no SIM, or Wi-Fi-only hardware). The property itself is present and undeprecated; there is simply nothing registered.",
                extra: ["knownConstantCount": String(NetworkProbeRadio.knownConstants.count)]))
        }

        // --- carrier identity (deprecated + hollowed out)
        let carriers = info.serviceSubscriberCellularProviders
        var carrierExtra: [String: String] = [:]
        var observed: [String] = []
        var allHollow = true

        if let carriers, !carriers.isEmpty {
            carrierExtra["serviceCount"] = String(carriers.count)
            for (service, c) in carriers.sorted(by: { $0.key < $1.key }) {
                let svc = NetworkProbeHash.tag(service, "svc")
                let name = c.carrierName
                let mcc = c.mobileCountryCode
                let mnc = c.mobileNetworkCode
                let iso = c.isoCountryCode
                carrierExtra["\(svc).carrierName"] = name ?? "nil"
                carrierExtra["\(svc).mobileCountryCode"] = mcc ?? "nil"
                carrierExtra["\(svc).mobileNetworkCode"] = mnc ?? "nil"
                carrierExtra["\(svc).isoCountryCode"] = iso ?? "nil"
                carrierExtra["\(svc).allowsVOIP"] = String(c.allowsVOIP)
                let hollow = NetworkProbeRadio.isHollow(name)
                    && NetworkProbeRadio.isHollow(mcc)
                    && NetworkProbeRadio.isHollow(mnc)
                if !hollow { allHollow = false }
                observed.append("\(svc): carrierName=\(name ?? "nil"), mcc=\(mcc ?? "nil"), mnc=\(mnc ?? "nil")")
            }
        }

        let carrierDetail = """
        VERIFIED against CoreTelephony/CTTelephonyNetworkInfo.h in the current SDK — do not \
        build anything on carrier identity:

          @property ... serviceSubscriberCellularProviders
              API_DEPRECATED("Deprecated with no replacement", ios(12.0, 16.0), watchos(5.0, 9.0));

        The property was deprecated outright in iOS 16.0 with NO replacement API, and from \
        iOS 16.4 onward the CTCarrier objects it returns are hollow: carrierName is the \
        two-character placeholder "--", mobileCountryCode and mobileNetworkCode are both \
        "65535" (the 3GPP reserved/test value), and isoCountryCode is "--". This is not a \
        permission or entitlement problem and there is no way to opt in — Apple removed the \
        data, not the access. The values actually observed on THIS device are recorded \
        verbatim in `extra` so the report proves it rather than asserting it. CTCarrier the \
        class is also deprecated. The only durable cellular signal left is \
        serviceCurrentRadioAccessTechnology (above) plus the pdp_ip0 byte counters (below); \
        carrier name, MCC, MNC and home-country are permanently gone as of iOS 16.4.
        """

        if carriers == nil {
            items.append(ProbeItem(
                "network.radio.carrier", "Carrier identity (CTCarrier)", .unavailable,
                value: "serviceSubscriberCellularProviders returned nil",
                detail: carrierDetail, extra: carrierExtra))
        } else if observed.isEmpty {
            items.append(ProbeItem(
                "network.radio.carrier", "Carrier identity (CTCarrier)", .empty,
                value: "empty dictionary — no cellular service present",
                detail: carrierDetail, extra: carrierExtra))
        } else {
            var carrierValue = "hollowed out — \(observed.count) service(s), all placeholder values"
            var fullDetail = carrierDetail
            if !allHollow {
                carrierValue = "\(observed.count) service(s), SOME REAL VALUES STILL RETURNED"
                fullDetail += "\n\nNOTE — this device returned at least one non-placeholder field, "
                    + "which contradicts the documented iOS 16.4+ behaviour. Observed: "
                    + observed.joined(separator: " | ")
                    + ". Treat that as a finding worth re-checking, not as a stable capability."
            }
            items.append(ProbeItem(
                "network.radio.carrier", "Carrier identity (CTCarrier)",
                allHollow ? .unavailable : .partial,
                value: carrierValue,
                detail: fullDetail,
                extra: carrierExtra))
        }

        return items
    }

    // 3 ------------------------------------------------------ NEHotspotNetwork

    static func hotspotItems() async -> [ProbeItem] {
        var items: [ProbeItem] = []

        let entitlementNote = """
        NEHotspotNetwork.fetchCurrent requires BOTH of the following, and returns nil \
        (never an error) if either is missing:
          (a) the com.apple.developer.networking.wifi-info entitlement — "Access WiFi \
              Information" — which must be enabled on the App ID in the developer portal and \
              re-embedded in the provisioning profile; a sideloaded build signed with a \
              plain personal-team profile does NOT have it; and
          (b) one of exactly four conditions listed verbatim in NEHotspotNetwork.h: the app \
              holds precise-location authorization, OR the app configured the current network \
              via NEHotspotConfiguration, OR the app has an active VPN configuration, OR the \
              app has an active NEDNSSettingsManager configuration.
        Condition (b) is why this probe runs after LocationProbe: precise-location \
        authorization granted earlier in the same report run is the cheapest way to satisfy \
        it. A nil result therefore does NOT distinguish "no entitlement" from "no location \
        permission" — check the entitlement item in the Entitlements section to tell them \
        apart.
        """

        let result = await NetworkProbeHotspot.fetch(timeout: 4.0)

        switch result {
        case .frameworkMissing:
            items.append(ProbeItem("network.wifi.current", "Current Wi-Fi network", .unavailable,
                                   value: "NetworkExtension not importable on this platform",
                                   detail: entitlementNote))

        case .timedOut:
            items.append(ProbeItem(
                "network.wifi.current", "Current Wi-Fi network", .error,
                value: "completion handler never fired (4.0s deadline)",
                detail: """
                fetchCurrentWithCompletionHandler: accepted the call but never invoked the \
                block. This is a real, reported failure mode rather than a hang in this probe \
                — the continuation was resumed by our own deadline, not left dangling. It \
                usually means the entitlement is absent and the daemon dropped the request \
                silently instead of calling back with nil.

                \(entitlementNote)
                """))

        case .nilResult:
            items.append(ProbeItem(
                "network.wifi.current", "Current Wi-Fi network", .denied,
                value: "nil — entitlement and/or the four-condition gate not satisfied",
                detail: """
                The completion handler fired promptly with nil. That is the documented \
                response to a missing entitlement or an unsatisfied precondition; it is NOT \
                "no Wi-Fi network". Cross-check network.path.current — if that reports Wi-Fi \
                as the primary interface while this returns nil, the phone is definitely \
                associated to an AP and the block is purely an authorization gate.

                \(entitlementNote)
                """))

        case let .found(ssidTag, bssidTag, oui, securityRaw):
            var extra: [String: String] = [
                "ssidHash": ssidTag,
                "bssidHash": bssidTag,
                "hashAlgorithm": NetworkProbeHash.algoNote
            ]
            if let oui { extra["bssidOUI"] = oui }
            // Unreachable in practice: securityType is unconditionally read at the
            // 17.0 deployment target. Kept only so the enum's Int? stays honest.
            var secLabel = "securityType not reported"
            if let securityRaw {
                extra["securityTypeRaw"] = String(securityRaw)
                secLabel = NetworkProbeHotspot.securityLabels[securityRaw] ?? "unrecognised(\(securityRaw))"
                extra["securityType"] = secLabel
                extra["isSecure"] = String(securityRaw != 0)
            }
            items.append(ProbeItem(
                "network.wifi.current", "Current Wi-Fi network", .ok,
                value: "\(ssidTag) · \(secLabel)",
                detail: """
                WHY THE SSID IS HASHED, AND WHY THAT LOSES NOTHING THAT MATTERS.

                The literal SSID is the single most place-revealing string a phone will hand \
                you — "Ahmed 5G", "TCB-Guest", "Marriott_Conf" each name a specific building \
                and, often, a specific person. It is also completely unnecessary for the \
                analysis anyone actually wants to run. Every question worth asking of Wi-Fi \
                telemetry is a question about IDENTITY OVER TIME, not about the name: is the \
                phone on the same network it was on last night (home), a network it sees five \
                weekdays a week between 8am and 6pm (office), or a network it has never seen \
                before (travel)? A stable hash answers all three, because the SAME network \
                always produces the SAME tag. What the hash removes is the ability to read \
                the answer as a human-legible place — which is precisely the part you do not \
                want sitting in a report you might share.

                The salt is a fixed compile-time constant, deliberately not random per run. A \
                per-run salt would make yesterday's tag and today's tag different for the same \
                network and destroy the entire longitudinal signal. Constant salt = \
                cross-report and cross-device comparability.

                HONEST CAVEAT, because the trade-off is real: SSIDs are low-entropy and the \
                salt is compiled into a binary the report's owner controls. Anyone holding \
                both the salt and a candidate list ("xfinitywifi", "Starbucks WiFi", a \
                surname) can confirm a guess by recomputing the hash. This is a dictionary \
                confirmation attack, not a break — it cannot enumerate unknown names, only \
                test ones you already suspect. For a personal, sideloaded, single-owner report \
                that is a sound trade: it stops casual disclosure and shoulder-surfing while \
                preserving the place-fingerprint. It is NOT anonymisation, and this data should \
                not be published on that basis.

                The BSSID (the AP's radio MAC) is hashed the same way, which distinguishes \
                individual access points inside one SSID — that is how you get room-level \
                granularity in a large office from a single flat network name. Its OUI (first \
                three octets) is reported IN THE CLEAR because it names the hardware vendor \
                (Cisco / Ubiquiti / eero / Apple) and not the household — vendor mix is useful \
                and identifies nobody.
                """,
                extra: extra))
        }

        // signalStrength: deliberately NOT called. Explained rather than guessed.
        items.append(ProbeItem(
            "network.wifi.signalStrength", "Wi-Fi signal strength (RSSI)", .unavailable,
            value: "not obtainable from a fetchCurrent() object",
            detail: """
            DELIBERATELY NOT CALLED, and the reason is a header discrepancy worth recording. \
            Apple's rendered documentation lists signalStrength / isSecure / didAutoJoin / \
            didJustJoin as members of NEHotspotNetwork, which makes them look freely available. \
            They are not members of the public class. NEHotspotNetwork.h declares exactly four \
            things — SSID, BSSID, securityType, and fetchCurrentWithCompletionHandler:. The \
            other four properties are declared in a SEPARATE header, NEHotspotHelper.h, as \
            `@interface NEHotspotNetwork (HotspotHelper)`, and that category exists to \
            annotate networks handed to a HotspotHelper — which requires \
            com.apple.developer.networking.HotspotHelper, an entitlement Apple grants only by \
            written application to hotspot operators.

            Crucially, NEHotspotNetwork.h states in its own comment that the object passed to \
            the fetchCurrent completion block "contains only valid SSID, BSSID and security \
            type values". So signalStrength on a fetchCurrent object is documented-invalid: it \
            would compile, return 0.0, and mean nothing. Recording a meaningless 0.0 as a \
            measurement is worse than recording its absence, so this probe reports \
            .unavailable and never links against the category at all.

            If Wi-Fi RSSI is genuinely needed, the only public substitutes are indirect: BLE \
            RSSI from the Bluetooth item below as a proximity proxy, or NWPath.isConstrained / \
            throughput measurement as a quality proxy. There is no public Wi-Fi RSSI on iOS.
            """,
            extra: ["publicHeaderMembers": "SSID, BSSID, securityType, fetchCurrentWithCompletionHandler:",
                    "categoryHeader": "NEHotspotHelper.h",
                    "categoryEntitlement": "com.apple.developer.networking.HotspotHelper (Apple-approved only)"]))

        return items
    }

    // 4 ----------------------------------------------- getifaddrs byte counters

    static func counterItems() async -> [ProbeItem] {
        var items: [ProbeItem] = []

        guard let first = NetworkProbeIfCounters.read() else {
            items.append(ProbeItem("network.bytes.interfaces", "Per-interface byte counters", .error,
                                   detail: "getifaddrs(3) returned non-zero."))
            return items
        }

        // Second sample gives a live throughput reading rather than only a
        // since-boot total — a real measurement, taken now.
        let gap = 1.5
        try? await Task.sleep(nanoseconds: UInt64(gap * 1_000_000_000))
        let second = NetworkProbeIfCounters.read()

        let uptime = ProcessInfo.processInfo.systemUptime
        let bootDate = Date(timeIntervalSinceNow: -uptime)

        let wifi = first.sum { $0.isWiFiClass }
        let cell = first.sum { $0.isCellular }
        let vpn = first.sum { $0.isVPN }
        let awdl = first.sum { $0.isAWDL }
        let ap = first.sum { $0.isHotspotAP && !$0.isWiFiClass }

        let width = first.byteFieldWidth
        let wrapAt: UInt64 = 4_294_967_296
        let wrapped = width == 4 && (wifi.inB > wrapAt / 2 || cell.inB > wrapAt / 2 || uptime > 86_400)

        // Hoisted out of the string below: multi-line expressions inside a
        // multiline-string interpolation are a parser hazard not worth taking.
        let plural = width == 1 ? "" : "s"
        let widthClause: String
        if width == 4 {
            widthClause = "That is 32 bits, so every figure below is bytes-since-boot MOD 4,294,967,296 (4.29 GB). "
                + "It silently wraps to zero and keeps counting; there is no overflow flag and no way to tell how many times it wrapped. "
                + "With systemUptime at \(ProbeEnv.num(uptime / 86_400)) days, Wi-Fi has very likely wrapped at least once, "
                + "so treat the Wi-Fi figure as a LOWER BOUND on the low 32 bits, not a total. "
                + "Cellular usually stays under 4.29 GB between reboots and is more often literal."
        } else {
            widthClause = "That is \(width * 8) bits, wide enough that wrapping is not a practical concern."
        }
        let vpnBytes = vpn.inB &+ vpn.outB
        let vpnClause: String
        if vpnBytes > 0 {
            vpnClause = "This device HAS live tunnel traffic (\(NetworkProbeFmt.bytes(vpnBytes)) on utun/ipsec/ppp), "
                + "so the Wi-Fi and cellular figures below are inflated by roughly that amount."
        } else {
            vpnClause = "No tunnel interface on this device is carrying traffic, so the figures below are not inflated by this effect."
        }

        let counterCaveat = """
        HOW TO READ THESE NUMBERS — three caveats, all of which change the answer:

        1. THEY ARE MODULO, NOT TOTAL. sizeof(if_data.ifi_ibytes) was measured at runtime on \
        this SDK and is \(width) byte\(plural). \(widthClause)

        2. THE OBVIOUS FIX IS NOT AVAILABLE ON iOS. On macOS you would use \
        sysctl(CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0) and read if_msghdr2.ifm_data as \
        if_data64, which gives non-wrapping 64-bit counters. That path CANNOT BE COMPILED for \
        an iOS device: net/route.h has never shipped in the iOS device SDK (only in the \
        simulator SDK), and routing sockets have never been a supported iOS API. This probe \
        therefore does not attempt it — the 32-bit getifaddrs counter is the ceiling of what \
        iOS exposes, not a lazy choice.

        3. VPN TRAFFIC IS COUNTED TWICE. A byte sent through a utun/ipsec tunnel is counted \
        once on the tunnel interface and again on the physical interface that carries it. \
        \(vpnClause)

        Counters reset to zero on reboot with no marker, which is why systemUptime is \
        reported alongside them: bytes ÷ uptime is the only way to turn an unanchored counter \
        into a comparable rate, and a small counter next to a large uptime means a quiet \
        period, not a fresh device.
        """

        var extra: [String: String] = [
            "ifDataByteFieldWidthBytes": String(width),
            "wrapModulusBytes": width == 4 ? String(wrapAt) : "n/a",
            "likelyWrapped": String(wrapped),
            "systemUptimeSeconds": String(format: "%.0f", uptime),
            "systemUptimeDays": ProbeEnv.num(uptime / 86_400),
            "estimatedBootTime": ProbeEnv.stamp(bootDate) ?? "?",
            "wifiInBytes": String(wifi.inB),
            "wifiOutBytes": String(wifi.outB),
            "cellularInBytes": String(cell.inB),
            "cellularOutBytes": String(cell.outB),
            "vpnInBytes": String(vpn.inB),
            "vpnOutBytes": String(vpn.outB),
            "awdlInBytes": String(awdl.inB),
            "awdlOutBytes": String(awdl.outB),
            "hotspotApInBytes": String(ap.inB),
            "hotspotApOutBytes": String(ap.outB),
            "interfaceCount": String(first.stats.count)
        ]
        if uptime > 0 {
            extra["wifiMeanBytesPerSecSinceBoot"] = String(format: "%.1f", Double(wifi.inB &+ wifi.outB) / uptime)
            extra["cellularMeanBytesPerSecSinceBoot"] = String(format: "%.1f", Double(cell.inB &+ cell.outB) / uptime)
        }

        items.append(ProbeItem(
            "network.bytes.wifi", "Wi-Fi bytes since boot (en*)",
            wifi.inB &+ wifi.outB > 0 ? (wrapped ? .partial : .ok) : .empty,
            value: "↓ \(NetworkProbeFmt.bytes(wifi.inB))  ↑ \(NetworkProbeFmt.bytes(wifi.outB))",
            detail: counterCaveat,
            extra: extra))

        items.append(ProbeItem(
            "network.bytes.cellular", "Cellular bytes since boot (pdp_ip*)",
            cell.inB &+ cell.outB > 0 ? .ok : .empty,
            value: "↓ \(NetworkProbeFmt.bytes(cell.inB))  ↑ \(NetworkProbeFmt.bytes(cell.outB))",
            detail: """
            pdp_ip0 is the primary cellular PDP context; pdp_ip1..n appear with dual-SIM or a \
            separate IMS/VoLTE context. This is the closest thing iOS has to a data-usage API \
            — there is no public equivalent of Settings > Cellular > Current Period, and that \
            Settings figure is maintained separately by the system and does NOT reset on \
            reboot, so the two will never agree. Cellular typically stays well under the \
            4.29 GB wrap between reboots, which makes it the more trustworthy of the two \
            counters.

            \(counterCaveat)
            """,
            extra: extra))

        // Per-interface breakdown: the aggregate is only interpretable with it.
        var breakdown: [String: String] = [:]
        var lines: [String] = []
        for s in first.stats.sorted(by: { $0.total > $1.total }) where s.total > 0 {
            breakdown["\(s.name).in"] = String(s.inBytes)
            breakdown["\(s.name).out"] = String(s.outBytes)
            breakdown["\(s.name).packetsIn"] = String(s.inPackets)
            breakdown["\(s.name).packetsOut"] = String(s.outPackets)
            if s.inErrors &+ s.outErrors > 0 {
                breakdown["\(s.name).errors"] = "in \(s.inErrors) / out \(s.outErrors)"
            }
            lines.append("\(s.name) ↓\(NetworkProbeFmt.bytes(s.inBytes)) ↑\(NetworkProbeFmt.bytes(s.outBytes))")
        }
        breakdown["interfacesWithTraffic"] = String(lines.count)

        items.append(ProbeItem(
            "network.bytes.interfaces", "Per-interface breakdown",
            lines.isEmpty ? .empty : .ok,
            value: lines.prefix(6).joined(separator: " · "),
            detail: """
            Interface naming on iOS, since the names are not self-explanatory and the \
            aggregates above are meaningless without them:
              en0      Wi-Fi station (the one that matters)
              en1/en2  usually the Personal Hotspot bridge or a USB/Thunderbolt Ethernet adapter
              ap1      Personal Hotspot access point — nonzero traffic here means this phone \
            was TETHERING, which is a genuinely useful behavioural signal
              pdp_ip0+ cellular PDP contexts
              utun*    VPN / iCloud Private Relay / Wireguard tunnels (double-counted, see above)
              ipsec*   IKEv2 / IPsec VPN
              awdl0    Apple Wireless Direct Link — AirDrop, AirPlay, Handoff, SharePlay. \
            Traffic here is peer-to-peer device-to-device and never touches the router, so it \
            is a proximity/social signal, not an internet-usage signal
              llw0     low-latency WLAN, sibling of awdl0
              lo0      loopback — local IPC, not network activity
            """,
            extra: breakdown))

        // Live throughput from the two samples.
        if let second {
            let elapsed = second.takenAt.timeIntervalSince(first.takenAt)
            var rates: [String: String] = ["sampleGapSeconds": String(format: "%.2f", elapsed)]
            var rateLines: [String] = []
            for s in second.stats {
                guard let prior = first.named(s.name) else { continue }
                let dIn = s.inBytes >= prior.inBytes ? s.inBytes - prior.inBytes : 0
                let dOut = s.outBytes >= prior.outBytes ? s.outBytes - prior.outBytes : 0
                guard dIn &+ dOut > 0 else { continue }
                rates["\(s.name).deltaIn"] = String(dIn)
                rates["\(s.name).deltaOut"] = String(dOut)
                if elapsed > 0 {
                    rates["\(s.name).bytesPerSec"] = String(format: "%.0f", Double(dIn &+ dOut) / elapsed)
                }
                let elapsedText = String(format: "%.1f", elapsed)
                rateLines.append("\(s.name) \(NetworkProbeFmt.bytes(dIn &+ dOut)) in \(elapsedText)s")
            }
            items.append(ProbeItem(
                "network.bytes.liveRate", "Live throughput (2 samples, " + String(format: "%.1f", gap) + "s apart)",
                rateLines.isEmpty ? .empty : .ok,
                value: rateLines.isEmpty ? "no interface moved a byte during the sample window" : rateLines.joined(separator: " · "),
                detail: "Two getifaddrs reads separated by a real sleep. Deltas are floor-clamped at zero so a 32-bit wrap between samples reports as 0 rather than as a spurious 4 GB spike. An idle window here is normal and is itself a datum — it means nothing but background daemons were on the wire during the probe.",
                extra: rates))
        }

        items.append(ProbeItem(
            "network.bytes.sysctlRoute", "64-bit counters via sysctl NET_RT_IFLIST2", .unavailable,
            value: "not compilable for an iOS device target",
            detail: "The macOS answer to the 32-bit wrap is sysctl(CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0), walking if_msghdr2 records and reading ifm_data as if_data64 (64-bit ifi_ibytes/ifi_obytes, no wrap). It is unavailable here for a structural reason, not a permissions one: net/route.h has never been included in the iOS device SDK — it ships only in the simulator SDK — and routing sockets have never been supported iOS API. Attempting it would fail at compile time on a device build. Recorded explicitly so nobody re-derives this dead end.",
            extra: ["blocker": "net/route.h absent from iOS device SDK", "macOSEquivalent": "NET_RT_IFLIST2 / if_msghdr2 / if_data64"]))

        return items
    }

    // 5 ----------------------------------------------------- CoreBluetooth scan

    static func bluetoothItems() async -> [ProbeItem] {
        var items: [ProbeItem] = []

        // Authorization BEFORE the manager exists. The transition across manager
        // creation is the finding — authorization and data availability are
        // different axes and they disagree constantly.
        let authBefore = CBManager.authorization

        let scanner = NetworkProbeBTScanner()
        let state = await scanner.startAndWaitForState(timeout: 6.0)
        let authAfter = CBManager.authorization

        var scanSeconds = 0.0
        if state == .poweredOn {
            scanSeconds = 4.0
            await scanner.scan(seconds: scanSeconds)
        }
        var result = scanner.snapshot()
        result.state = NetworkProbeBT.stateName(state)
        result.reachedPoweredOn = state == .poweredOn
        result.scanSeconds = scanSeconds

        // Unconditional teardown on every path, including the timeout path.
        scanner.shutdown()

        items.append(ProbeItem(
            "network.bluetooth.authorization", "Bluetooth authorization",
            NetworkProbeBT.authStatus(authAfter),
            value: authBefore == authAfter
                ? NetworkProbeBT.authName(authAfter)
                : "\(NetworkProbeBT.authName(authBefore)) → \(NetworkProbeBT.authName(authAfter))",
            detail: """
            CBManager.authorization is sampled twice: once before any CBCentralManager exists \
            and once after. That is deliberate. On iOS 13+ the Bluetooth permission prompt is \
            raised by the ACT OF CREATING a central manager, not by scanning, so a \
            notDetermined → allowedAlways transition across those two reads is the report \
            catching the prompt in the act. If both reads say notDetermined the prompt never \
            appeared, which almost always means NSBluetoothAlwaysUsageDescription is missing \
            from Info.plist — iOS suppresses the prompt silently rather than crashing on a \
            central-manager init.

            Authorization is a SEPARATE axis from radio state. allowedAlways with the radio \
            switched off yields zero peripherals and is not a permission failure; denied with \
            the radio on also yields zero. The next item reports radio state so the two can be \
            told apart.
            """,
            extra: ["authorizationBefore": NetworkProbeBT.authName(authBefore),
                    "authorizationAfter": NetworkProbeBT.authName(authAfter),
                    "changedDuringProbe": String(authBefore != authAfter),
                    "promptTrigger": "CBCentralManager init, not scanForPeripherals"]))

        var stateStatus: ProbeStatus = .partial
        switch state {
        case .poweredOn: stateStatus = .ok
        case .poweredOff: stateStatus = .empty
        case .unauthorized: stateStatus = .denied
        case .unsupported: stateStatus = .unavailable
        default: stateStatus = .partial
        }

        items.append(ProbeItem(
            "network.bluetooth.state", "Bluetooth radio state", stateStatus,
            value: NetworkProbeBT.stateName(state),
            detail: "CBCentralManager was created with CBCentralManagerOptionShowPowerAlertKey:false so an off radio is OBSERVED rather than turned into a modal alert at the user mid-report. `.unknown` here would mean the delegate never reported a state within 6s; `.resetting` means the Bluetooth daemon is restarting and a retry would likely succeed.",
            extra: ["rawState": String(state.rawValue),
                    "showPowerAlert": "false"]))

        if state == .poweredOn {
            let rssis = result.distinct.map { $0.rssi }.filter { $0 != 127 && $0 < 0 }
            var extra: [String: String] = [
                "distinctPeripherals": String(result.distinct.count),
                "scanSeconds": String(format: "%.1f", scanSeconds),
                "allowDuplicates": "false",
                "serviceFilter": "nil (all advertisers)",
                "connectableAdvertisements": String(result.connectableAds),
                "advertisementsWithServiceUUIDs": String(result.serviceUUIDAds),
                "advertisementsWithLocalName": String(result.localNameAds),
                "advertisementsWithManufacturerData": String(result.manufacturerAds),
                "distinctCompanyIDs": String(result.companyIDs.count),
                "rssiSampleCount": String(rssis.count)
            ]

            if !rssis.isEmpty {
                let sorted = rssis.sorted()
                let n = sorted.count
                let sum = sorted.reduce(0, +)
                let minV = sorted.first ?? 0
                let maxV = sorted.last ?? 0
                let midIdx = n / 2
                let median: Double
                if n % 2 == 1 {
                    median = midIdx < n ? Double(sorted[midIdx]) : 0
                } else if midIdx >= 1 && midIdx < n {
                    median = (Double(sorted[midIdx - 1]) + Double(sorted[midIdx])) / 2
                } else {
                    median = Double(minV)
                }
                extra["rssiMin"] = String(minV)
                extra["rssiMax"] = String(maxV)
                extra["rssiMean"] = String(format: "%.1f", Double(sum) / Double(n))
                extra["rssiMedian"] = String(format: "%.1f", median)

                var buckets: [String: Int] = [:]
                for r in sorted { buckets[NetworkProbeBT.bucket(r), default: 0] += 1 }
                for (b, c) in buckets.sorted(by: { $0.key < $1.key }) {
                    extra["rssiBucket · \(b)"] = String(c)
                }
                extra["veryClose(≥-50dBm)Count"] = String(sorted.filter { $0 >= -50 }.count)
            }

            var companyList: [String] = []
            for cid in result.companyIDs.sorted() {
                let name = NetworkProbeBT.companyNames[cid] ?? "unassigned/unlisted"
                companyList.append("0x" + String(format: "%04X", Int(cid)) + " (\(name))")
            }
            if !companyList.isEmpty {
                extra["companyIDs"] = companyList.joined(separator: ", ")
                extra["appleAdvertisersPresent"] = String(result.companyIDs.contains(0x004C))
            }

            // Hashed identifiers + RSSI, strongest first, capped so a dense
            // environment does not bloat the report.
            for (i, d) in result.distinct.prefix(24).enumerated() {
                extra["peripheral[\(i)]"] = "\(d.tag) @ \(d.rssi) dBm"
            }

            let scanLabel = "BLE crowd scan (" + String(format: "%.0f", scanSeconds) + "s)"
            var scanValue = "\(result.distinct.count) distinct peripheral(s)"
            if let lo = rssis.min(), let hi = rssis.max() {
                scanValue += ", RSSI \(lo)…\(hi) dBm"
            }

            items.append(ProbeItem(
                "network.bluetooth.scan", scanLabel,
                result.distinct.isEmpty ? .empty : .ok,
                value: scanValue,
                detail: """
                WHAT THIS IS ACTUALLY MEASURING. A passive BLE scan with \
                allowDuplicates:false returns each advertiser once, so the count is a census \
                of powered BLE devices within roughly 10–30 m — a crowd/density proxy that \
                works indoors where GPS does not. Empirically: single digits at home, \
                20–60 in an open-plan office, 100+ on a train or in a bar. The RSSI \
                distribution adds shape: a cluster above -50 dBm means devices at arm's \
                length (a meeting, a queue), a long tail below -85 dBm means a large open \
                space. Manufacturer-data company IDs give the device MIX — a room that is \
                90% Apple advertisers is a different room from one that is mostly Nordic \
                Semiconductor beacons.

                IDENTIFIERS ARE HASHED, AND ARE NOT STABLE ANYWAY. CBPeripheral.identifier \
                is already an app-and-device-scoped UUID rather than the hardware BD_ADDR, \
                and modern peripherals rotate their resolvable private address roughly every \
                15 minutes, so the same physical AirPod appears as a different identifier \
                later in the day. Consequence: this count is a good CROWD measure and a poor \
                RE-IDENTIFICATION measure — do not try to build "have I seen this device \
                before" on it. Advertised local names are counted but NEVER recorded, because \
                BLE local names are frequently a person's actual name.

                THE BACKGROUND RESTRICTION, which decides whether this is ever automatable. In \
                the foreground, withServices:nil scans for everything — which is what this \
                probe does. The moment the app is backgrounded that stops working: iOS \
                requires background scans to name EXPLICIT service UUIDs \
                (scanForPeripherals(withServices: [CBUUID], …)), silently drops the \
                CBCentralManagerScanOptionAllowDuplicatesKey option, and coalesces \
                discoveries of the same peripheral into a single callback. A nil service \
                filter in the background returns nothing at all — no error, just silence. So \
                an unattended crowd-density collector is NOT possible with this technique \
                unless you can enumerate in advance the service UUIDs you care about, and \
                most consumer devices advertise only manufacturer data with no service UUID. \
                This measurement is inherently foreground-and-attended.
                """,
                extra: extra))
        } else {
            items.append(ProbeItem(
                "network.bluetooth.scan", "BLE crowd scan",
                state == .unauthorized ? .denied : (state == .unsupported ? .unavailable : .empty),
                value: "not attempted — radio state \(NetworkProbeBT.stateName(state))",
                detail: "A scan is only started once the central manager reports .poweredOn; starting one earlier is a no-op that CoreBluetooth logs and discards. The manager was created, awaited, and then torn down cleanly (stopScan + delegate = nil) regardless of outcome.",
                extra: ["radioState": NetworkProbeBT.stateName(state)]))
        }

        return items
    }

    // 6 ------------------------------------------- Bluetooth audio via AVAudioSession

    static func audioRouteItems() -> [ProbeItem] {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute

        let btOutputTypes: Set<AVAudioSession.Port> = [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE]
        let btOutputs = route.outputs.filter { btOutputTypes.contains($0.portType) }
        let btInputs = route.inputs.filter { $0.portType == .bluetoothHFP }

        var extra: [String: String] = [
            "outputCount": String(route.outputs.count),
            "inputCount": String(route.inputs.count),
            "bluetoothOutputCount": String(btOutputs.count),
            "bluetoothInputCount": String(btInputs.count)
        ]
        for (i, p) in route.outputs.enumerated() {
            // portType is a system constant and identifies nobody. portName is
            // the user's own label ("Zach's AirPods Pro") and is hashed.
            extra["output[\(i)].portType"] = p.portType.rawValue
            extra["output[\(i)].portNameHash"] = NetworkProbeHash.tag(p.portName, "port")
            extra["output[\(i)].uidHash"] = NetworkProbeHash.tag(p.uid, "uid")
            if let ch = p.channels { extra["output[\(i)].channels"] = String(ch.count) }
        }
        for (i, p) in route.inputs.enumerated() {
            extra["input[\(i)].portType"] = p.portType.rawValue
            extra["input[\(i)].portNameHash"] = NetworkProbeHash.tag(p.portName, "port")
        }

        let allTypes = route.outputs.map { $0.portType.rawValue }.joined(separator: ", ")
        let btTypes = btOutputs.map { $0.portType.rawValue }.joined(separator: ", ")
        let routeValue: String
        if btOutputs.isEmpty {
            routeValue = "no Bluetooth audio route — current output: " + (allTypes.isEmpty ? "none" : allTypes)
        } else {
            routeValue = "\(btOutputs.count) Bluetooth output(s): " + btTypes
        }

        return [ProbeItem(
            "network.bluetooth.audioRoute", "Connected Bluetooth audio (via AVAudioSession)",
            btOutputs.isEmpty ? .empty : .ok,
            value: routeValue,
            detail: """
            THIS — NOT CoreBluetooth — IS THE PATH THAT ACTUALLY WORKS FOR AIRPODS AND CAR \
            STEREOS, and the distinction costs people days.

            CoreBluetooth only ever sees BLE advertisers and peripherals your app has \
            explicitly connected to. Classic Bluetooth audio devices — AirPods on A2DP, a car \
            head unit on handsfree, any speaker — are NOT enumerable through CBCentralManager. \
            retrieveConnectedPeripherals(withServices:) does not help either: it returns only \
            peripherals connected via BLE GATT with the service UUIDs you name, so it returns \
            an empty array for AirPods. There is no public API that lists paired or connected \
            classic Bluetooth devices on iOS. The External Accessory framework covers only \
            MFi-programme accessories, which consumer audio gear is not.

            What DOES work is the audio route: AVAudioSession.currentRoute exposes any \
            Bluetooth device currently carrying audio, typed as BluetoothA2DP (stereo — \
            headphones, speakers, car), BluetoothHFP (handsfree/mic — phone calls, car voice) \
            or BluetoothLE (LE Audio). That is both a device-presence signal and, more \
            usefully, a CONTEXT signal: BluetoothHFP on the input side almost always means \
            an active call or a car; a CarPlay-adjacent A2DP route means driving.

            Its limits, stated plainly: it sees only devices routing audio RIGHT NOW, not \
            everything paired, and it cannot see a connected-but-silent device. Read here \
            without activating or reconfiguring the session, so it does not disturb \
            AmbientProbe — cross-reference that section, which reads the same route object \
            for microphone and output-volume context.
            """,
            extra: extra)]
    }

    // 7 ------------------------------------------------ Local network permission

    static func localNetworkItems() -> [ProbeItem] {
        let info = Bundle.main.infoDictionary
        let usage = info?["NSLocalNetworkUsageDescription"] as? String
        let bonjour = info?["NSBonjourServices"] as? [String]
        let btAlways = info?["NSBluetoothAlwaysUsageDescription"] as? String

        var extra: [String: String] = [
            "NSLocalNetworkUsageDescription.present": String(usage != nil),
            "NSBonjourServices.present": String(bonjour != nil),
            "NSBonjourServices.count": String(bonjour?.count ?? 0),
            "NSBluetoothAlwaysUsageDescription.present": String(btAlways != nil),
            "browseAttempted": "false"
        ]
        if let usage { extra["NSLocalNetworkUsageDescription"] = usage }
        if let bonjour { extra["NSBonjourServices"] = bonjour.joined(separator: ", ") }

        let status: ProbeStatus = usage == nil ? .unavailable : .notDetermined

        return [ProbeItem(
            "network.localNetwork.permission", "Local Network permission",
            status,
            value: usage == nil
                ? "NSLocalNetworkUsageDescription ABSENT from Info.plist"
                : "declared; not exercised (no browse performed)",
            detail: """
            NO BONJOUR BROWSE WAS STARTED. That is intentional and it is why this item reports \
            .\(status.rawValue) rather than a granted/denied answer: the only way to learn the \
            local-network authorization state on iOS is to trigger the prompt, and triggering \
            it would (a) put a modal in front of the user mid-report and (b) permanently move \
            the app from notDetermined into an answered state, destroying the very thing a \
            later run would want to measure. There is no read-only status API — no \
            LocalNetworkAuthorization.status, nothing in NWPathMonitor. The state is \
            write-only until you provoke it.

            WHAT THE PLIST KEY DOES AND DOES NOT DO — documented, NOT measured on this device: \
            NSLocalNetworkUsageDescription does not itself prompt. It is the purpose string \
            iOS displays WHEN a prompt is triggered, and the prompt is triggered by the first \
            actual attempt to reach the local network — a Bonjour/mDNS browse or advertisement \
            via NWBrowser/NWListener or NetService, a multicast or broadcast send, or a direct \
            connection to a local-subnet address. If the key is missing, iOS on recent releases \
            suppresses the prompt and denies local-network access outright rather than asking, \
            and the failure surfaces as an empty browse with no error. The key became \
            effectively mandatory around iOS 18 for apps that touch the local network, having \
            been more loosely enforced on iOS 17. Grants are per-app and revocable in Settings \
            > Privacy & Security > Local Network; developers have reported that toggling it \
            back on does not always take effect until the app — sometimes the device — is \
            restarted. Treat the phrasing here as documented behaviour with a known \
            enforcement change at iOS 18, not as a measurement from this handset.

            Note also that NWPath.UnsatisfiedReason gained a `localNetworkDenied` case, so a \
            path monitor CAN report the denial indirectly — but only for a connection already \
            attempted, which brings the same side effect.
            """,
            extra: extra)]
    }

    // 8 ------------------------------------------------------------ MAC address

    static func macItems() -> [ProbeItem] {
        var extra: [String: String] = [:]
        var observed: [String] = []
        var anyReal = false

        if let sample = NetworkProbeIfCounters.read() {
            for s in sample.stats {
                guard let mac = s.linkAddress else { continue }
                let isNulled = mac == "02:00:00:00:00:00" || mac == "00:00:00:00:00:00"
                extra["\(s.name).linkAddress"] = isNulled ? mac : NetworkProbeHash.tag(mac, "mac")
                extra["\(s.name).isSentinel"] = String(isNulled)
                if !isNulled { anyReal = true }
                if s.name == "en0" || s.name.hasPrefix("pdp_ip") {
                    observed.append("\(s.name)=\(isNulled ? mac : "hashed")")
                }
            }
        }

        extra["sentinelValue"] = "02:00:00:00:00:00"

        return [ProbeItem(
            "network.mac.hardwareAddress", "Wi-Fi / hardware MAC address",
            anyReal ? .partial : .unavailable,
            value: anyReal
                ? "some interfaces returned a non-sentinel link address (hashed)"
                : "02:00:00:00:00:00 — permanently sentinelled",
            detail: """
            KILL THIS IDEA BEFORE ANYONE SPENDS TIME ON IT. The device MAC address is not \
            obtainable on iOS, by any public route, and it would not be useful even if it were.

            Two independent walls, either of which is fatal on its own:

            1. THE API IS SENTINELLED. Since iOS 7, every documented route to the hardware \
            address — getifaddrs + sockaddr_dl (what this item just executed and reports \
            above), sysctl, and CNCopy* — returns the fixed placeholder 02:00:00:00:00:00 for \
            en0 instead of the real address. This probe reads the link-layer address for every \
            interface and records what actually came back, so the report demonstrates the \
            sentinel rather than asserting it. There is no entitlement, no permission prompt, \
            and no user consent flow that lifts this; the only ways past it are private \
            frameworks or IOKit paths that App Review rejects and that Apple has repeatedly \
            broken across releases. Out of scope here on principle.

            2. EVEN A REAL MAC WOULD BE MEANINGLESS. Since iOS 14 the device uses a Private \
            Wi-Fi Address: a DIFFERENT randomised MAC per SSID, on by default for every \
            network, and from iOS 18 it additionally ROTATES periodically on networks the \
            device does not treat as trusted. So "the device's MAC" is not a single stable \
            value that exists to be read — it is a per-network, time-varying pseudonym by \
            design. Anything built on MAC-as-device-identity is broken at the concept level, \
            not merely blocked at the API level.

            WHAT TO USE INSTEAD, per purpose:
              • stable per-install device identity → UIDevice.identifierForVendor (already in \
            the report envelope) or a Keychain-persisted UUID that survives reinstall;
              • "am I on the network I was on before" → the hashed SSID/BSSID pair in \
            network.wifi.current, which is exactly the durable place-identity that a MAC is \
            usually being reached for;
              • nearby-device presence → the BLE scan above.
            Observed link addresses: \(observed.isEmpty ? "none readable" : observed.joined(separator: ", ")).
            """,
            extra: extra)]
    }
}

// MARK: - Summary

enum NetworkProbeSummary {
    static func text(_ items: [ProbeItem]) -> String {
        var t: [ProbeStatus: Int] = [:]
        for i in items { t[i.status, default: 0] += 1 }
        let counts = [
            "\(t[.ok] ?? 0) ok",
            "\(t[.partial] ?? 0) partial",
            "\(t[.empty] ?? 0) empty",
            "\(t[.denied] ?? 0) denied",
            "\(t[.notDetermined] ?? 0) notDetermined",
            "\(t[.unavailable] ?? 0) unavailable",
            "\(t[.error] ?? 0) error"
        ].joined(separator: " · ")

        return """
        \(items.count) checks — \(counts).

        WHAT SURVIVES ON THIS STACK. Four things still yield real signal: the NWPath snapshot \
        (interface list in routing-preference order, isExpensive/isConstrained, IPv4/IPv6/DNS \
        support), the per-service radio access technology (raw CTRadioAccessTechnology* \
        constants — the one CoreTelephony property that is NOT deprecated), the per-interface \
        byte counters from getifaddrs, and a foreground BLE crowd scan. Everything else in \
        this section is a documented dead end, recorded here so it is never re-litigated.

        THREE DEAD ENDS, EACH VERIFIED AGAINST THE ACTUAL SDK HEADER RATHER THAN THE RENDERED \
        DOCS, WHICH DISAGREE:

        • CARRIER IDENTITY IS GONE. serviceSubscriberCellularProviders is \
        API_DEPRECATED("Deprecated with no replacement", ios(12.0, 16.0)) and since iOS 16.4 \
        the CTCarrier objects are hollow — carrierName "--", MCC/MNC "65535". The values this \
        device actually returned are in the item's extras as proof. Do not build on carrier \
        name; there is no replacement API and none is coming.

        • WI-FI RSSI IS NOT PUBLIC. NEHotspotNetwork.h declares exactly four members (SSID, \
        BSSID, securityType, fetchCurrentWithCompletionHandler:). signalStrength, isSecure, \
        didAutoJoin and didJustJoin — which Apple's website lists as though they were freely \
        available — live in NEHotspotHelper.h behind the Apple-approved HotspotHelper \
        entitlement, and the public header states that a fetchCurrent object carries only \
        valid SSID, BSSID and security type. This probe therefore never links that category \
        and derives "is the network secure" from securityType instead. Reporting the 0.0 that \
        signalStrength would have returned would have been reporting noise as a measurement.

        • 64-BIT BYTE COUNTERS CANNOT BE COMPILED. sysctl NET_RT_IFLIST2 / if_msghdr2 / \
        if_data64 is the macOS fix for the 32-bit wrap; net/route.h has never shipped in the \
        iOS device SDK, so it is a build error, not a runtime failure. The width of \
        if_data.ifi_ibytes is measured at runtime and reported, so the report states whether \
        its own numbers are modulo 4.29 GB rather than assuming. VPN/utun traffic is \
        double-counted against the physical interface and is flagged when present.

        MAC ADDRESSES ARE NOT OBTAINABLE — full stop. The link-layer address is read for every \
        interface and the sentinel 02:00:00:00:00:00 is reported verbatim so the report \
        demonstrates the wall instead of asserting it; and since iOS 14 Private Wi-Fi Address \
        gives a different randomised MAC per SSID (rotating on untrusted networks from iOS 18), \
        so even a real value would not be a device identity. Use identifierForVendor, or the \
        hashed SSID/BSSID, depending on which question is actually being asked.

        BLE SCANNING IS FOREGROUND-ONLY IN PRACTICE. The 4-second passive scan uses \
        withServices:nil, which works only while the app is foregrounded. Backgrounded, iOS \
        requires explicit service UUIDs, drops allowDuplicates, and coalesces callbacks — a \
        nil filter returns nothing, silently. An unattended crowd-density collector is not \
        achievable this way. Separately, AirPods and car stereos are invisible to \
        CoreBluetooth entirely; AVAudioSession.currentRoute is the path that works for them, \
        and it is read here without activating the session so AmbientProbe is undisturbed.

        PRIVACY POSTURE. SSID, BSSID, BLE peripheral UUIDs, CoreTelephony service IDs and \
        audio port names are reported as salted SHA-256 tags, never in the clear. The salt is \
        a fixed constant, not per-run, because the whole value of the tag is that the same \
        network yields the same tag across reports and devices — that comparability IS the \
        place fingerprint. The honest limit: SSIDs are low-entropy and the salt is in the \
        binary, so a known candidate name can be confirmed by recomputation. That is a \
        dictionary confirmation, not a break, and it is an acceptable trade for a personal \
        sideloaded report — but this is pseudonymisation, not anonymisation. BSSID OUIs are \
        left in the clear deliberately: they name the AP vendor, not the household.

        NO PROMPT WAS TRIGGERED FOR LOCAL NETWORK. No Bonjour browse was started, because \
        provoking the prompt is the only way to read that authorization state and doing so \
        would burn the notDetermined state a future run wants to observe. Only the presence \
        of NSLocalNetworkUsageDescription and NSBonjourServices is reported. Bluetooth is the \
        opposite case and is prompted deliberately: CBManager.authorization is sampled before \
        AND after the central manager is created so the report captures the transition, since \
        authorization state and data availability are different axes that disagree constantly.

        DELIBERATELY OMITTED: NET_RT_IFLIST2 (uncompilable, above); the NEHotspotHelper \
        category (above); CFNetworkCopySystemProxySettings — its __SCOPED__ keys are a decent \
        VPN/proxy detector, but VPN presence is already covered by utun/ipsec interfaces in \
        the byte-counter breakdown and its current-SDK surface was not verified, so it was \
        left out rather than risked; and NEHotspotConfiguration, which joins networks rather \
        than reporting them and has side effects a read-only probe must not have.
        """
    }
}
