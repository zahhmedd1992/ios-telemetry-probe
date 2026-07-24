import Foundation
import CoreFoundation
import Security

// MARK: - EntitlementProbe
//
// The load-bearing probe. Everything else in this app asks "does this API
// return data?"; this one asks "what did the signing toolchain actually grant
// us?" — which is the question that decides whether the other probes can ever
// work at all.
//
// Three independent lines of evidence, deliberately kept separate because they
// disagree in practice:
//
//   1. WHAT WAS REQUESTED / ALLOWED — the `Entitlements` dictionary inside
//      `embedded.mobileprovision`. This is what the signing team is permitted
//      to ask for. It is NOT proof the running binary carries them.
//   2. WHAT IS ACTUALLY GRANTED — measured, not read. We write a real file
//      into the App Group container and add a real keychain item. If those
//      succeed, the entitlement survived signing. If the container is nil, it
//      did not, no matter what the profile claims.
//   3. HOW THE BINARY IS SIGNED — presence of `_CodeSignature`, the receipt
//      filename, `get-task-allow`.
//
// DELIBERATE OMISSION: there is no public iOS API to read the running binary's
// real entitlement blob. `SecTaskCopyValueForEntitlement` is not exported on
// iOS and `SecCodeCopySigningInformation` is macOS-only; both are out of bounds
// under this project's "public API only" rule. That gap is precisely why
// evidence line (2) exists — the write tests are the ground truth.
//
// Also note: this project's `project.yml` builds UNSIGNED
// (`CODE_SIGNING_ALLOWED: NO`) and ad-hoc signs a second copy. A missing
// `embedded.mobileprovision` is therefore an expected, informative outcome —
// not a probe failure — and is reported as such.

struct EntitlementProbe: TelemetryProbe {
    let key = "entitlement"
    let title = "Signing & Entitlements"

    func run() async -> ProbeSection {
        var items: [ProbeItem] = []

        // ------------------------------------------------------------------
        // 0. Bundle identity
        // ------------------------------------------------------------------
        let bundle = Bundle.main
        items.append(ProbeItem(
            "entitlement.bundle.identifier",
            "Bundle identifier",
            bundle.bundleIdentifier == nil ? .error : .ok,
            value: bundle.bundleIdentifier ?? "unavailable",
            extra: [
                "bundlePath": bundle.bundlePath,
                "executable": (bundle.infoDictionary?["CFBundleExecutable"] as? String) ?? "?"
            ]
        ))

        // ------------------------------------------------------------------
        // 1. Locate and parse embedded.mobileprovision
        // ------------------------------------------------------------------
        let profileURL = bundle.url(forResource: "embedded", withExtension: "mobileprovision")
        let profileData: Data? = profileURL.flatMap { try? Data(contentsOf: $0) }

        var profile: [String: Any] = [:]
        var profileParseNote = ""
        var haveProfile = false

        if let profileURL, let profileData {
            let parsed = EntitlementProbeSupport.extractPlist(from: profileData)
            switch parsed {
            case .success(let dict):
                profile = dict
                haveProfile = true
                items.append(ProbeItem(
                    "entitlement.profile.present",
                    "embedded.mobileprovision",
                    .ok,
                    value: "present — \(ProbeEnv.int(profileData.count)) bytes, \(ProbeEnv.int(dict.count)) top-level keys",
                    detail: "CMS/PKCS#7 container; the XML plist payload was extracted by byte range (no Security.framework CMS decode needed).",
                    extra: [
                        "path": profileURL.lastPathComponent,
                        "containerBytes": String(profileData.count),
                        "topLevelKeys": String(dict.count)
                    ]
                ))
            case .failure(let why):
                profileParseNote = why
                items.append(ProbeItem(
                    "entitlement.profile.present",
                    "embedded.mobileprovision",
                    .error,
                    value: "present but unparseable",
                    detail: "\(ProbeEnv.int(profileData.count)) bytes on disk. \(why)"
                ))
            }
        } else {
            items.append(ProbeItem(
                "entitlement.profile.present",
                "embedded.mobileprovision",
                .unavailable,
                value: "absent — ad-hoc / unsigned build",
                detail: "No provisioning profile is embedded in this bundle. That means the binary was either built unsigned or ad-hoc signed with no profile, so NO capability-gated entitlement (HealthKit, App Groups, push, Family Controls) can possibly be in force. This is the expected result for the tier-0 build (Probe.entitlements requests no provisioned capability). The App Group and keychain write tests below are the definitive check either way."
            ))
        }

        // ------------------------------------------------------------------
        // 2. Profile metadata
        // ------------------------------------------------------------------
        if haveProfile {
            items.append(contentsOf: EntitlementProbeSupport.metadataItems(profile))
        } else {
            for meta in EntitlementProbeSupport.metadataKeyOrder {
                items.append(ProbeItem(
                    "entitlement.profile.\(meta.0)",
                    meta.1,
                    .unavailable,
                    detail: profileParseNote.isEmpty
                        ? "No provisioning profile in the bundle to read this from."
                        : profileParseNote
                ))
            }
        }

        // ------------------------------------------------------------------
        // 3. Entitlements dictionary — full dump, then the named checklist
        // ------------------------------------------------------------------
        let entitlements = profile["Entitlements"] as? [String: Any] ?? [:]

        if haveProfile {
            items.append(ProbeItem(
                "entitlement.ents.count",
                "Entitlement keys in profile",
                entitlements.isEmpty ? .empty : .ok,
                value: ProbeEnv.int(entitlements.count),
                detail: entitlements.isEmpty
                    ? "The profile carries no Entitlements dictionary, or it is empty."
                    : "Every key below is dumped verbatim from the profile's Entitlements dictionary.",
                extra: ["keys": entitlements.keys.sorted().joined(separator: ", ")]
            ))
        }

        for entKey in entitlements.keys.sorted() {
            let raw = entitlements[entKey] ?? ""
            items.append(ProbeItem(
                "entitlement.ent.\(entKey)",
                entKey,
                .ok,
                value: EntitlementProbeSupport.stringify(raw),
                detail: "Verbatim from the profile's Entitlements dictionary.",
                extra: ["type": EntitlementProbeSupport.typeName(raw)]
            ))
        }

        for spec in EntitlementProbeSupport.checklist {
            if let raw = entitlements[spec.key] {
                items.append(ProbeItem(
                    "entitlement.check.\(spec.key)",
                    "\(spec.label) — provisioned",
                    .ok,
                    value: EntitlementProbeSupport.stringify(raw),
                    detail: "\(spec.note) Gate: \(spec.gate). Present in the profile means the signing team was ALLOWED to request it — it does not prove the running binary carries it.",
                    extra: ["entitlementKey": spec.key, "gate": spec.gate, "present": "true"]
                ))
            } else {
                items.append(ProbeItem(
                    "entitlement.check.\(spec.key)",
                    "\(spec.label) — not provisioned",
                    .unavailable,
                    value: "absent",
                    detail: haveProfile
                        ? "`\(spec.key)` was not provisioned in this profile. \(spec.note) Gate: \(spec.gate)."
                        : "No provisioning profile is present, so `\(spec.key)` cannot be in force. \(spec.note) Gate: \(spec.gate).",
                    extra: ["entitlementKey": spec.key, "gate": spec.gate, "present": "false"]
                ))
            }
        }

        // ------------------------------------------------------------------
        // 4. Provisioning verdict: development vs ad-hoc vs App Store
        // ------------------------------------------------------------------
        let getTaskAllow = EntitlementProbeSupport.boolValue(entitlements["get-task-allow"])
        let provisionsAll = EntitlementProbeSupport.boolValue(profile["ProvisionsAllDevices"]) ?? false
        let deviceList = profile["ProvisionedDevices"] as? [Any]
        let apsEnv = entitlements["aps-environment"] as? String

        // Hoisted out of the interpolations below: nested string literals
        // inside nested closures inside interpolations are legal but fragile.
        let deviceCountText = deviceList.map { ProbeEnv.int($0.count) } ?? "0"
        let apsText: String
        if let apsEnv {
            apsText = " aps-environment = \(apsEnv)."
        } else {
            apsText = ""
        }

        let verdict: (String, ProbeStatus, String)
        if !haveProfile {
            verdict = (
                "ad-hoc / unsigned",
                .partial,
                "No embedded profile at all. The binary was signed ad-hoc (or not signed), so it runs only on a device that trusts the signing certificate, and it carries no provisioned capability. Any HealthKit / App Groups / push feature is unreachable in this configuration regardless of what the .entitlements file requested at build time."
            )
        } else if provisionsAll {
            verdict = (
                "enterprise (in-house) distribution",
                .ok,
                "ProvisionsAllDevices = true, which only an Apple Developer Enterprise Program profile carries. Installs on any device, no UDID registration."
            )
        } else if getTaskAllow == true {
            verdict = (
                "development",
                .ok,
                "get-task-allow = true means the binary is debuggable and this is a development profile. Device installs are limited to the \(deviceCountText) UDIDs registered in the profile.\(apsText)"
            )
        } else if let deviceList, !deviceList.isEmpty {
            verdict = (
                "ad-hoc distribution",
                .ok,
                "get-task-allow is false but the profile pins \(ProbeEnv.int(deviceList.count)) specific devices — that is ad-hoc distribution, not App Store.\(apsText)"
            )
        } else {
            verdict = (
                "App Store distribution",
                .ok,
                "get-task-allow is false and no devices are pinned — an App Store (or TestFlight) distribution profile.\(apsText)"
            )
        }

        items.append(ProbeItem(
            "entitlement.signing.type",
            "Provisioning type",
            verdict.1,
            value: verdict.0,
            detail: verdict.2,
            extra: [
                "getTaskAllow": getTaskAllow.map { $0 ? "true" : "false" } ?? "absent",
                "provisionsAllDevices": provisionsAll ? "true" : "false",
                "provisionedDeviceCount": deviceList.map { String($0.count) } ?? "0",
                "apsEnvironment": apsEnv ?? "absent"
            ]
        ))

        // ------------------------------------------------------------------
        // 5. App Groups — MEASURED, not read. Write a real file.
        // ------------------------------------------------------------------
        var groupIDs: [String] = [EntitlementProbeSupport.canonicalAppGroup]
        if let declared = entitlements["com.apple.security.application-groups"] as? [Any] {
            for g in declared {
                if let s = g as? String, !groupIDs.contains(s) { groupIDs.append(s) }
            }
        }

        var anyGroupWorked = false
        for gid in groupIDs {
            let result = EntitlementProbeSupport.testAppGroup(gid)
            if result.status == .ok { anyGroupWorked = true }
            items.append(result.item)
        }

        // ------------------------------------------------------------------
        // 6. Keychain — the fallback shared store. Also measured.
        // ------------------------------------------------------------------
        items.append(EntitlementProbeSupport.testKeychain())

        // ------------------------------------------------------------------
        // 7. Code-signing artifacts observable from inside the sandbox
        // ------------------------------------------------------------------
        items.append(contentsOf: EntitlementProbeSupport.codeSignatureItems(bundle))

        // ------------------------------------------------------------------
        // 8. Summary computed from what was actually found
        // ------------------------------------------------------------------
        var bits: [String] = []
        bits.append(haveProfile ? "Profile present (\(verdict.0))." : "No embedded profile — \(verdict.0).")
        if let ttl = EntitlementProbeSupport.totalValidityDays(profile) {
            let cls = EntitlementProbeSupport.classifyTTL(ttl)
            bits.append("Profile validity \(ProbeEnv.num(ttl)) days → \(cls).")
        }
        if haveProfile {
            let named = EntitlementProbeSupport.checklist.filter { entitlements[$0.key] != nil }.count
            bits.append("\(ProbeEnv.int(entitlements.count)) entitlement keys, \(named)/\(EntitlementProbeSupport.checklist.count) of the tracked capabilities provisioned.")
        }
        bits.append(anyGroupWorked
            ? "App Group container IS writable — extensions can feed the collector."
            : "App Group container is NOT available — no app extension can hand data to this app.")
        bits.append("Research note (2026, and it is contested): a free Apple ID personal team gets 7-day profiles, 10 App IDs and 3 devices, and Xcode is widely reported to refuse entitlement-backed capabilities (App Groups, push, iCloud, associated domains) — yet Apple's own supported-capabilities table ticks HealthKit, App Groups, Family Controls (development) and WeatherKit for free \"Apple Developer\" accounts. The items above, not that note, are the authority for THIS build.")
        bits.append("Caveat: the profile lists what the team may REQUEST. iOS has no public API to read the running binary's granted entitlement blob, so the App Group and keychain write tests above are the only ground truth.")

        return section(bits.joined(separator: " "), items)
    }
}

// MARK: - Support (all file-private, all prefixed — nothing here can collide)

private enum EntitlementProbeSupport {

    static let canonicalAppGroup = "group.com.zacharyahmed.telemetryprobe"

    // MARK: Profile plist extraction

    enum ExtractResult {
        case success([String: Any])
        case failure(String)
    }

    /// `embedded.mobileprovision` is a CMS (PKCS#7) SignedData blob whose payload
    /// is an XML plist. Rather than pull in Security.framework's CMS decoder
    /// (which is macOS-only for the useful entry points), slice the payload out
    /// by locating the first `<?xml` and the LAST `</plist>`. Trailing signature
    /// bytes must be cut or PropertyListSerialization rejects the whole thing.
    static func extractPlist(from data: Data) -> ExtractResult {
        guard let open = data.range(of: Data("<?xml".utf8)) else {
            return .failure("No `<?xml` marker found in the \(data.count)-byte container.")
        }
        guard let close = data.range(of: Data("</plist>".utf8), options: .backwards) else {
            return .failure("Found `<?xml` at byte \(open.lowerBound) but no closing `</plist>`.")
        }
        guard open.lowerBound < close.upperBound else {
            return .failure("Malformed container: `</plist>` at byte \(close.lowerBound) precedes `<?xml` at byte \(open.lowerBound).")
        }
        let xml = data.subdata(in: open.lowerBound..<close.upperBound)
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard let obj = try? PropertyListSerialization.propertyList(from: xml,
                                                                   options: [],
                                                                   format: &format) else {
            return .failure("Extracted a \(xml.count)-byte XML payload but PropertyListSerialization could not parse it.")
        }
        guard let dict = obj as? [String: Any] else {
            return .failure("Parsed the payload but the root object is not a dictionary.")
        }
        return .success(dict)
    }

    // MARK: Metadata

    /// (item-key suffix, human label) — also used to emit placeholders when
    /// there is no profile, so the report shape is stable across builds.
    static let metadataKeyOrder: [(String, String)] = [
        ("name", "Profile name"),
        ("teamName", "Team name"),
        ("teamIdentifier", "Team identifier"),
        ("appIDName", "App ID name"),
        ("applicationIdentifierPrefix", "App ID prefix"),
        ("uuid", "Profile UUID"),
        ("platform", "Platform"),
        ("isXcodeManaged", "Xcode-managed"),
        ("creationDate", "Creation date"),
        ("expirationDate", "Expiration date"),
        ("daysUntilExpiry", "Days until expiry"),
        ("totalValidity", "Total profile validity"),
        ("timeToLive", "TimeToLive (declared)"),
        ("provisionsAllDevices", "Provisions all devices"),
        ("provisionedDevices", "Provisioned devices"),
        ("developerCertificates", "Developer certificates"),
        ("version", "Profile format version")
    ]

    static func metadataItems(_ p: [String: Any]) -> [ProbeItem] {
        var out: [ProbeItem] = []

        func str(_ suffix: String, _ label: String, _ plistKey: String) {
            if let v = p[plistKey] {
                out.append(ProbeItem("entitlement.profile.\(suffix)", label, .ok,
                                     value: stringify(v),
                                     extra: ["profileKey": plistKey]))
            } else {
                out.append(ProbeItem("entitlement.profile.\(suffix)", label, .unavailable,
                                     detail: "Key `\(plistKey)` is not present in this profile."))
            }
        }

        str("name", "Profile name", "Name")
        str("teamName", "Team name", "TeamName")

        // TeamIdentifier is an array; surface the first element as the value.
        if let team = p["TeamIdentifier"] as? [Any] {
            let first = (team.first as? String) ?? "?"
            out.append(ProbeItem("entitlement.profile.teamIdentifier", "Team identifier", .ok,
                                 value: first,
                                 detail: team.count > 1 ? "Profile carries \(team.count) team identifiers: \(stringify(team))." : nil,
                                 extra: ["count": String(team.count), "all": stringify(team)]))
        } else {
            str("teamIdentifier", "Team identifier", "TeamIdentifier")
        }

        str("appIDName", "App ID name", "AppIDName")
        str("applicationIdentifierPrefix", "App ID prefix", "ApplicationIdentifierPrefix")
        str("uuid", "Profile UUID", "UUID")

        if let plat = p["Platform"] {
            out.append(ProbeItem("entitlement.profile.platform", "Platform", .ok,
                                 value: stringify(plat)))
        } else {
            out.append(ProbeItem("entitlement.profile.platform", "Platform", .unavailable,
                                 detail: "Key `Platform` is not present in this profile."))
        }

        if let managed = boolValue(p["IsXcodeManaged"]) {
            out.append(ProbeItem("entitlement.profile.isXcodeManaged", "Xcode-managed", .ok,
                                 value: managed ? "true" : "false",
                                 detail: managed
                                    ? "Xcode generated and refreshes this profile automatically (typical of free-provisioning and automatic signing)."
                                    : "Manually created profile from the developer portal."))
        } else {
            out.append(ProbeItem("entitlement.profile.isXcodeManaged", "Xcode-managed", .unavailable,
                                 detail: "Key `IsXcodeManaged` is not present in this profile."))
        }

        let created = p["CreationDate"] as? Date
        let expires = p["ExpirationDate"] as? Date

        if let created {
            out.append(ProbeItem("entitlement.profile.creationDate", "Creation date", .ok,
                                 value: ProbeEnv.stamp(created) ?? "?",
                                 detail: ProbeEnv.age(created).map { "Signed \($0)." },
                                 extra: ["epoch": String(Int(created.timeIntervalSince1970))]))
        } else {
            out.append(ProbeItem("entitlement.profile.creationDate", "Creation date", .unavailable,
                                 detail: "Key `CreationDate` is not present in this profile."))
        }

        if let expires {
            out.append(ProbeItem("entitlement.profile.expirationDate", "Expiration date", .ok,
                                 value: ProbeEnv.stamp(expires) ?? "?",
                                 extra: ["epoch": String(Int(expires.timeIntervalSince1970))]))

            // THE TELL. A free Apple ID personal team gets a 7-day profile;
            // a paid Developer Program membership gets ~365 days.
            let remaining = expires.timeIntervalSinceNow / 86_400.0
            let status: ProbeStatus = remaining <= 0 ? .error : (remaining < 2 ? .partial : .ok)
            let expiredNote = remaining <= 0
                ? "EXPIRED. The app will refuse to launch until it is re-signed."
                : "Re-sign before this date or the app stops launching."
            out.append(ProbeItem(
                "entitlement.profile.daysUntilExpiry",
                "Days until expiry",
                status,
                value: String(format: "%.2f days", remaining),
                detail: "\(expiredNote) Days REMAINING is not itself the free-vs-paid tell — the total validity span below is.",
                extra: [
                    "daysRemaining": String(format: "%.4f", remaining),
                    "hoursRemaining": String(format: "%.1f", remaining * 24)
                ]
            ))
        } else {
            out.append(ProbeItem("entitlement.profile.expirationDate", "Expiration date", .unavailable,
                                 detail: "Key `ExpirationDate` is not present in this profile."))
            out.append(ProbeItem("entitlement.profile.daysUntilExpiry", "Days until expiry", .unavailable,
                                 detail: "No ExpirationDate to measure against."))
        }

        if let ttl = totalValidityDays(p) {
            out.append(ProbeItem(
                "entitlement.profile.totalValidity",
                "Total profile validity",
                .ok,
                value: String(format: "%.2f days — %@", ttl, classifyTTL(ttl)),
                detail: "ExpirationDate minus CreationDate. This is the definitive free-vs-paid signal: Xcode issues 7-day profiles to a free Apple ID personal team and ~365-day profiles to a paid Apple Developer Program membership.",
                extra: ["totalDays": String(format: "%.4f", ttl), "classification": classifyTTL(ttl)]
            ))
        } else {
            out.append(ProbeItem("entitlement.profile.totalValidity", "Total profile validity", .unavailable,
                                 detail: "Needs both CreationDate and ExpirationDate; at least one is missing."))
        }

        if let ttl = p["TimeToLive"] {
            out.append(ProbeItem("entitlement.profile.timeToLive", "TimeToLive (declared)", .ok,
                                 value: "\(stringify(ttl)) days",
                                 detail: "The profile's own declared lifetime in days, independent of the date arithmetic above."))
        } else {
            out.append(ProbeItem("entitlement.profile.timeToLive", "TimeToLive (declared)", .unavailable,
                                 detail: "Key `TimeToLive` is not present in this profile."))
        }

        let provisionsAll = boolValue(p["ProvisionsAllDevices"]) ?? false
        out.append(ProbeItem(
            "entitlement.profile.provisionsAllDevices",
            "Provisions all devices",
            .ok,
            value: provisionsAll ? "true" : "false",
            detail: provisionsAll
                ? "Enterprise (in-house) profile — installs on any device with no UDID registration."
                : "Standard profile — installs are limited to the UDIDs listed below."
        ))

        if let devices = p["ProvisionedDevices"] as? [Any] {
            out.append(ProbeItem(
                "entitlement.profile.provisionedDevices",
                "Provisioned devices",
                devices.isEmpty ? .empty : .ok,
                value: ProbeEnv.int(devices.count),
                detail: "UDIDs pinned in the profile. A free personal team is capped far lower than a paid membership's 100-per-device-class allowance. UDIDs are deliberately not printed.",
                extra: ["count": String(devices.count)]
            ))
        } else {
            out.append(ProbeItem("entitlement.profile.provisionedDevices", "Provisioned devices", .unavailable,
                                 detail: provisionsAll
                                    ? "Absent because ProvisionsAllDevices is true (enterprise profile)."
                                    : "Key `ProvisionedDevices` is not present — typical of an App Store distribution profile."))
        }

        if let certs = p["DeveloperCertificates"] as? [Any] {
            var bytes = 0
            for c in certs { if let d = c as? Data { bytes += d.count } }
            out.append(ProbeItem(
                "entitlement.profile.developerCertificates",
                "Developer certificates",
                .ok,
                value: "\(ProbeEnv.int(certs.count)) cert(s), \(ProbeEnv.int(bytes)) bytes",
                detail: "DER-encoded signing certificates embedded in the profile. Contents are not decoded here (that would need Security.framework certificate parsing and adds nothing to the entitlement question).",
                extra: ["count": String(certs.count), "totalBytes": String(bytes)]
            ))
        } else {
            out.append(ProbeItem("entitlement.profile.developerCertificates", "Developer certificates", .unavailable,
                                 detail: "Key `DeveloperCertificates` is not present in this profile."))
        }

        str("version", "Profile format version", "Version")
        return out
    }

    static func totalValidityDays(_ p: [String: Any]) -> Double? {
        guard let c = p["CreationDate"] as? Date, let e = p["ExpirationDate"] as? Date else { return nil }
        let d = e.timeIntervalSince(c) / 86_400.0
        return d > 0 ? d : nil
    }

    static func classifyTTL(_ days: Double) -> String {
        if days <= 10 { return "FREE Apple ID personal team (7-day profile)" }
        if days >= 300 { return "PAID Apple Developer Program ($99/yr, ~1-year profile)" }
        return "unusual span — neither the 7-day free nor the ~365-day paid shape"
    }

    // MARK: Named entitlement checklist

    struct ChecklistEntry {
        let key: String
        let label: String
        let gate: String
        let note: String
    }

    static let checklist: [ChecklistEntry] = [
        .init(key: "application-identifier",
              label: "App ID (team prefix + bundle id)",
              gate: "baseline — any signed build",
              note: "Present on every signed binary; its prefix is the team ID."),
        .init(key: "com.apple.developer.team-identifier",
              label: "Team identifier",
              gate: "baseline — any signed build",
              note: "Identifies the signing team; also scopes default keychain access."),
        .init(key: "get-task-allow",
              label: "Debuggable (get-task-allow)",
              gate: "baseline — development builds only",
              note: "true means a debugger can attach. Distribution builds are always false."),
        .init(key: "com.apple.developer.healthkit",
              label: "HealthKit",
              gate: "capability — requires a provisioned App ID",
              note: "The single highest-value data stream in this app. Without it every HealthKit read fails regardless of the user granting permission."),
        .init(key: "com.apple.developer.healthkit.background-delivery",
              label: "HealthKit background delivery",
              gate: "capability — requires a provisioned App ID",
              note: "Required for HKObserverQuery to wake the app when new samples land; without it Health data can only be pulled while the app is foregrounded."),
        .init(key: "com.apple.developer.healthkit.access",
              label: "HealthKit access (clinical records)",
              gate: "capability — requires a provisioned App ID",
              note: "An empty array is normal; a non-empty array requests clinical health-record types, which additionally require Apple review."),
        .init(key: "com.apple.security.application-groups",
              label: "App Groups",
              gate: "capability — requires a provisioned App ID",
              note: "Load-bearing: an app extension has no other way to hand data to its host app. The write test below is the real answer."),
        .init(key: "aps-environment",
              label: "Push notifications (APS environment)",
              gate: "capability — requires a provisioned App ID",
              note: "Value is `development` or `production`; also a clean dev-vs-distribution tell."),
        .init(key: "com.apple.developer.networking.wifi-info",
              label: "Wi-Fi info (SSID / BSSID)",
              gate: "capability — requires a provisioned App ID",
              note: "Without it, CNCopyCurrentNetworkInfo returns nil and the SSID cannot be used as a place fingerprint."),
        .init(key: "com.apple.developer.family-controls",
              label: "Family Controls (Screen Time)",
              gate: "APPLE APPROVAL required — request form, not self-serve",
              note: "The only export channel for Screen Time / DeviceActivity data. Expected to be absent."),
        .init(key: "com.apple.developer.sensorkit.reader.allow",
              label: "SensorKit reader",
              gate: "APPLE APPROVAL required — research-use review",
              note: "Apple's research-grade sensor firehose. Granted essentially only to approved research studies."),
        .init(key: "keychain-access-groups",
              label: "Keychain access groups",
              gate: "capability — requires a provisioned App ID",
              note: "Absent is normal: the binary still gets an implicit access group equal to its application-identifier. The keychain test below measures the real behaviour."),
        .init(key: "com.apple.developer.associated-domains",
              label: "Associated domains",
              gate: "capability — requires a provisioned App ID",
              note: "Universal links and shared web credentials."),
        .init(key: "com.apple.developer.siri",
              label: "Siri",
              gate: "capability — requires a provisioned App ID",
              note: "Legacy SiriKit intents. App Intents / Shortcuts do NOT need this entitlement, which is worth knowing before paying for it."),
        .init(key: "com.apple.developer.weatherkit",
              label: "WeatherKit",
              gate: "capability — requires a provisioned App ID (500k calls/mo included with the paid program)",
              note: "Environmental context without a third-party API key."),
        .init(key: "com.apple.developer.usernotifications.filtering",
              label: "Notification filtering",
              gate: "APPLE APPROVAL required — request form",
              note: "The only public route to reading incoming notification content, via a notification service extension.")
    ]

    // MARK: App Group write test — MEASURED

    struct AppGroupResult {
        let status: ProbeStatus
        let item: ProbeItem
    }

    static func testAppGroup(_ gid: String) -> AppGroupResult {
        let itemKey = "entitlement.appgroup.\(gid)"
        let fm = FileManager.default

        guard let container = fm.containerURL(forSecurityApplicationGroupIdentifier: gid) else {
            return AppGroupResult(status: .unavailable, item: ProbeItem(
                itemKey,
                "App Group container: \(gid)",
                .unavailable,
                value: "nil — NOT granted",
                detail: "containerURL(forSecurityApplicationGroupIdentifier:) returned nil. This is the definitive answer that the App Groups entitlement is not in force on the running binary, whatever the profile or the .entitlements file says. Consequence: no app extension (widget, notification service, Live Activity) can ever hand data to this app — the collector must do all of its own I/O in-process.",
                extra: ["groupID": gid, "granted": "false"]
            ))
        }

        let probeFile = container.appendingPathComponent("entitlement-probe-\(UUID().uuidString).bin")
        let payload = Data("probe-\(Int(Date().timeIntervalSince1970))".utf8)

        do {
            try payload.write(to: probeFile, options: .atomic)
        } catch {
            return AppGroupResult(status: .error, item: ProbeItem(
                itemKey,
                "App Group container: \(gid)",
                .error,
                value: "container resolved but write FAILED",
                detail: "The container URL resolved to \(container.path) but writing a \(payload.count)-byte file into it failed: \(error.localizedDescription)",
                extra: ["groupID": gid, "granted": "partial", "containerPath": container.path]
            ))
        }

        let readBack = try? Data(contentsOf: probeFile)
        let matched = readBack == payload
        var freeBytes = "?"
        if let vals = try? container.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let cap = vals.volumeAvailableCapacityForImportantUsage {
            freeBytes = String(cap)
        }
        try? fm.removeItem(at: probeFile)
        let cleaned = !fm.fileExists(atPath: probeFile.path)

        return AppGroupResult(status: matched ? .ok : .partial, item: ProbeItem(
            itemKey,
            "App Group container: \(gid)",
            matched ? .ok : .partial,
            value: matched ? "GRANTED — wrote, read back and deleted \(payload.count) bytes" : "wrote but read-back mismatched",
            detail: "Container: \(container.path). This is a real filesystem round-trip, not a capability lookup — it is the ground truth for whether app extensions can feed this app. Temp file removed: \(cleaned ? "yes" : "NO — a stray file was left behind").",
            extra: [
                "groupID": gid,
                "granted": matched ? "true" : "partial",
                "containerPath": container.path,
                "bytesWritten": String(payload.count),
                "bytesReadBack": String(readBack?.count ?? 0),
                "volumeAvailableBytes": freeBytes,
                "cleanedUp": cleaned ? "true" : "false"
            ]
        ))
    }

    // MARK: Keychain test — MEASURED

    static func testKeychain() -> ProbeItem {
        let service = "com.zacharyahmed.telemetryprobe.entitlementprobe"
        let account = "keychain-selftest"
        let payload = Data("probe-\(Int(Date().timeIntervalSince1970))".utf8)

        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        // Delete first so a leftover item from a previous run cannot make the
        // add fail with errSecDuplicateItem and read as a denial.
        let preDelete = SecItemDelete(base as CFDictionary)

        var addQuery = base
        addQuery[kSecValueData as String] = payload
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)

        var readQuery = base
        readQuery[kSecReturnData as String] = true
        readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let readStatus = SecItemCopyMatching(readQuery as CFDictionary, &out)
        let readData = out as? Data
        let matched = (addStatus == errSecSuccess) && (readStatus == errSecSuccess) && (readData == payload)

        let postDelete = SecItemDelete(base as CFDictionary)

        let extra: [String: String] = [
            "preDeleteStatus": "\(preDelete) \(osStatusName(preDelete))",
            "addStatus": "\(addStatus) \(osStatusName(addStatus))",
            "readStatus": "\(readStatus) \(osStatusName(readStatus))",
            "postDeleteStatus": "\(postDelete) \(osStatusName(postDelete))",
            "bytesWritten": String(payload.count),
            "bytesReadBack": String(readData?.count ?? 0),
            "roundTripMatched": matched ? "true" : "false"
        ]

        if matched {
            return ProbeItem(
                "entitlement.keychain.roundtrip",
                "Keychain round-trip (shared-storage fallback)",
                .ok,
                value: "OK — added, read back and deleted \(payload.count) bytes",
                detail: "Generic-password item written and read via Security.framework with kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly. The keychain works, so it is a viable cross-launch store even if the App Group container is unavailable — but note the keychain is scoped to the application-identifier access group, so it can only be SHARED with an extension if a keychain-access-groups entitlement is provisioned.",
                extra: extra
            )
        }

        // -34018 is errSecMissingEntitlement. Compared as a literal because the
        // named constant's availability in the iOS Security overlay has moved
        // between SDK releases, and a build failure here is unacceptable.
        let missingEntitlement: OSStatus = -34018
        if addStatus == missingEntitlement || readStatus == missingEntitlement {
            return ProbeItem(
                "entitlement.keychain.roundtrip",
                "Keychain round-trip (shared-storage fallback)",
                .unavailable,
                value: "errSecMissingEntitlement (-34018)",
                detail: "The keychain refused the operation for lack of a keychain access group. On an unsigned or ad-hoc-signed binary with no application-identifier entitlement this is the expected and informative answer, not a bug: this build has no keychain at all, so any persistence must use the app sandbox's own Documents/Application Support directory.",
                extra: extra
            )
        }

        return ProbeItem(
            "entitlement.keychain.roundtrip",
            "Keychain round-trip (shared-storage fallback)",
            .error,
            value: "add \(osStatusName(addStatus)) / read \(osStatusName(readStatus))",
            detail: "The keychain round-trip did not complete. add=\(addStatus) (\(osStatusName(addStatus))), read=\(readStatus) (\(osStatusName(readStatus))), bytes back=\(readData?.count ?? 0) of \(payload.count).",
            extra: extra
        )
    }

    static func osStatusName(_ s: OSStatus) -> String {
        switch s {
        case 0: return "errSecSuccess"
        case -4: return "errSecUnimplemented"
        case -50: return "errSecParam"
        case -108: return "errSecAllocate"
        case -25291: return "errSecNotAvailable"
        case -25293: return "errSecAuthFailed"
        case -25299: return "errSecDuplicateItem"
        case -25300: return "errSecItemNotFound"
        case -25308: return "errSecInteractionNotAllowed"
        case -26275: return "errSecDecode"
        case -34018: return "errSecMissingEntitlement"
        default: return "unmapped OSStatus"
        }
    }

    // MARK: Code-signature artifacts

    static func codeSignatureItems(_ bundle: Bundle) -> [ProbeItem] {
        var out: [ProbeItem] = []
        let fm = FileManager.default

        let sigDir = bundle.bundleURL.appendingPathComponent("_CodeSignature")
        var isDir: ObjCBool = false
        let sigExists = fm.fileExists(atPath: sigDir.path, isDirectory: &isDir) && isDir.boolValue
        var contents: [String] = []
        if sigExists {
            contents = (try? fm.contentsOfDirectory(atPath: sigDir.path)) ?? []
        }
        let resources = sigDir.appendingPathComponent("CodeResources")
        var resourceBytes = 0
        if let attrs = try? fm.attributesOfItem(atPath: resources.path),
           let size = attrs[.size] as? NSNumber {
            resourceBytes = size.intValue
        }

        out.append(ProbeItem(
            "entitlement.signature.codeSignatureDir",
            "_CodeSignature directory",
            sigExists ? .ok : .unavailable,
            value: sigExists ? "present — \(contents.count) file(s)" : "absent",
            detail: sigExists
                ? "The bundle carries a sealed resource manifest, so its resources were signed. CodeResources is \(ProbeEnv.int(resourceBytes)) bytes. This proves the RESOURCES were sealed; it says nothing about which entitlements the executable's signature carries — iOS exposes no public API for that."
                : "No _CodeSignature directory in the bundle. The app was installed without a sealed resource manifest, which points at an unsigned or minimally ad-hoc-signed install.",
            extra: [
                "path": sigDir.path,
                "fileCount": String(contents.count),
                "files": contents.sorted().joined(separator: ", "),
                "codeResourcesBytes": String(resourceBytes)
            ]
        ))

        if let receipt = bundle.appStoreReceiptURL {
            let name = receipt.lastPathComponent
            let exists = fm.fileExists(atPath: receipt.path)
            var bytes = 0
            if exists,
               let attrs = try? fm.attributesOfItem(atPath: receipt.path),
               let size = attrs[.size] as? NSNumber {
                bytes = size.intValue
            }
            let interpretation: String
            switch name {
            case "sandboxReceipt":
                interpretation = "`sandboxReceipt` means a development, TestFlight or sideloaded install — NOT an App Store purchase."
            case "receipt":
                interpretation = "`receipt` means a production App Store install."
            default:
                interpretation = "Unrecognised receipt filename."
            }
            out.append(ProbeItem(
                "entitlement.signature.receipt",
                "App Store receipt",
                exists ? .ok : .empty,
                value: "\(name) — \(exists ? "file present, \(ProbeEnv.int(bytes)) bytes" : "path exists but NO file on disk")",
                detail: "\(interpretation) The URL is populated even when no receipt was ever issued, so the filename is the signal and the file's existence is a separate fact — a sideloaded build normally shows `sandboxReceipt` with no file behind it.",
                extra: [
                    "lastPathComponent": name,
                    "fileExists": exists ? "true" : "false",
                    "bytes": String(bytes),
                    "path": receipt.path
                ]
            ))
        } else {
            out.append(ProbeItem(
                "entitlement.signature.receipt",
                "App Store receipt",
                .unavailable,
                value: "appStoreReceiptURL is nil",
                detail: "The bundle reports no receipt URL at all."
            ))
        }

        return out
    }

    // MARK: Value stringification

    static func boolValue(_ v: Any?) -> Bool? {
        guard let n = v as? NSNumber else { return nil }
        return n.boolValue
    }

    static func typeName(_ v: Any) -> String {
        switch v {
        case is String: return "string"
        case is Date: return "date"
        case is Data: return "data"
        case let n as NSNumber: return isBoolNumber(n) ? "bool" : "number"
        case is [Any]: return "array"
        case is [String: Any]: return "dict"
        default: return String(describing: type(of: v))
        }
    }

    static func isBoolNumber(_ n: NSNumber) -> Bool {
        CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    /// Recursive, order-stable stringifier. Plist `<true/>` bridges to
    /// NSNumber, so booleans are detected by CFTypeID rather than `as? Bool`
    /// (which would also succeed for integers).
    static func stringify(_ v: Any) -> String {
        switch v {
        case let s as String:
            return s
        case let d as Date:
            return ProbeEnv.stamp(d) ?? String(describing: d)
        case let d as Data:
            return "<\(d.count) bytes>"
        case let n as NSNumber:
            return isBoolNumber(n) ? (n.boolValue ? "true" : "false") : n.stringValue
        case let a as [Any]:
            if a.isEmpty { return "[] (empty array)" }
            return "[" + a.map { stringify($0) }.joined(separator: ", ") + "]"
        case let d as [String: Any]:
            if d.isEmpty { return "{} (empty dict)" }
            return "{" + d.keys.sorted().map { k in
                "\(k): \(stringify(d[k] ?? ""))"
            }.joined(separator: ", ") + "}"
        default:
            return String(describing: v)
        }
    }
}
