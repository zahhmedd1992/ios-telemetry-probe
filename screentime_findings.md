# Screen Time domain — verified findings (2026-07-24)

## THE GATE (primary source)
https://developer.apple.com/help/account/reference/supported-capabilities-ios/
Table "Supported capabilities (iOS)" columns = ADP | ADEP | Apple Developer (free).
- **Family Controls (development) \*** → ADP=YES, ADEP=NO, **Apple Developer (free)=NO**. (\* = development only)
- App groups → ADP=YES, ADEP=YES, **Apple Developer (free)=YES**
=> Free Apple ID CANNOT sign Family Controls at all. $99/yr ADP required.
=> Once in ADP, DEV entitlement is self-serve (docs: "you can access the entitlement
   through the Apple Developer Program during development"). Distribution needs the form.

## iOS versions
iOS 26.5 = shipping. iOS 27 announced WWDC 8 Jun 2026, dev beta 3 on 6 Jul, public beta Jul 2026,
GM ~Sept 2026. No DeviceActivity/FamilyControls/ManagedSettings symbol is flagged beta at 27.0.

## iOS 26.4 — the big change (DMA/EU)
- New entitlement `com.apple.developer.family-controls.app-and-website-usage`
- `AuthorizationStatus.approvedWithDataAccess`
- `FamilyActivityData.shared.installedApplications` → [Application] with **bundleIdentifier AND token**
- `.visitedWebDomains` → [WebDomain] with domain + token
- `.activityCategories` → Set<ActivityCategory> with localizedDisplayName + token
- `DeviceActivityData.activityData(filteredBy:using:)` → AsyncSequence<DeviceActivityData>
  IN-PROCESS. No report extension. Exportable. Policy .cached / .live
- Apple: "You can develop and test an app that uses this method on devices in any region.
  Customer installations ... only ... in the EU with an EU Apple Account."

## iOS 26.5
ManagedSettingsStore: `stores`, `isActive`, `deleteStore()`, `deleteStores(_:)`,
`refresh(_:)` x3 (tokens EXPIRE), `TokenExpiryMessage` NotificationCenter.

## Sandboxes (Apple's own words)
- DeviceActivityReport: "your extension runs in a sandbox. This sandbox prevents your extension
  from making network requests or moving sensitive content outside the extension's address space."
- ShieldConfigurationDataSource: SAME sentence. (also: system DOES give it display names,
  bundle identifiers, domains)
- ShieldActionDelegate: system does NOT provide names, only tokens.
- DeviceActivityMonitor: NO sandbox language in Apple docs.

## Limits
- 20 activities max (MonitoringError.excessiveActivities) — community number, Apple doc only names error
- schedule interval: min 15 min, max 1 week (community)
- 50 named ManagedSettingsStores per process (WWDC22)
- 50 tokens per shield setting, fails SILENTLY (community)
- monitor ext memory: 5-6 MB (community/Jetsam)
- report ext RAM: <100MB

## Backfill
- Apple engineer, forums/thread/718683: "Once your app has successfully received authorization
  using FamilyControls, your DeviceActivityReportExtension will have access to up to a month of
  device activity data from that date onward."
- Monitor thresholds: forward only (includesPastActivity iOS 17.4 = within current interval only)

## knowledgeC / RMAdminStore
Full-filesystem-only. NOT in iTunes/Finder backup. knowledgeC superseded by Biome (SEGB) since iOS 16.
=> impossible on non-jailbroken device.

## Technique
matteing.com: 12 two-hour schedules x 24 events at 5-min thresholds = full-day 5-min resolution.
