# iOS PERSONAL TELEMETRY — MASTER DECISION DOCUMENT
**Target:** self-installed quantified-self app · iPhone + Apple Watch + AirPods + iPad · Windows-only build machine · free Apple ID (with a $99 decision to be made deliberately)
**Platform baseline:** iOS 26.5 shipping · iOS 27 at developer beta 4 (2026-07-20), GA ~2026-09-14. **Build against iphoneos26.x, deployment target 26.0.** Every iOS 27 claim below is docs-verified only (no public SDK mirror exists past iPhoneOS26.5.sdk).

---

## 0. THE ONE FORK THAT DECIDES THE BUILD

Before anything else: **there is a single unresolved fact that changes the shape of the entire project, and it is testable in about four hours.**

Apple's [supported-capabilities-ios](https://developer.apple.com/help/account/reference/supported-capabilities-ios/) table has three columns — ADP, ADEP, and "Apple Developer" (the free Personal Team). Three researchers independently parsed the **raw HTML** of that table (the checkmarks render as `<figure class="icon icon-checksolid">` with no text content, and page-summarizers hallucinate them). All three agree the free column has exactly **nine** checks:

```
App groups · Background modes · Data protection · HealthKit · HomeKit
Inter-App Audio · Keychain sharing · Maps · Wireless Accessory Configuration
```

**HealthKit is in that list.** So is Background modes. So is App groups. If that table is authoritative for what a Personal Team can provision, Tier 0 is enormous.

**The counter-evidence:** AltSign — the signing library behind *both* AltStore and SideStore — supports exactly six entitlements (`application-identifier`, `keychain-access-groups`, `com.apple.security.application-groups`, `get-task-allow`, `com.apple.developer.team-identifier`, `inter-app-audio`) and three features (`gameCenter`, App Groups `APG3427HIY`, Inter-App Audio `IAD53UNK2F`). `com.apple.developer.healthkit` appears nowhere in it. AltStore/SideStore **literally cannot request HealthKit in a profile.**

**Reconciliation:** AltSign's allowlist is a property of AltStore's implementation, not of Apple's membership tier. Sideloadly uses a zsign-lineage signer and re-signs against an Xcode-style personal-team development profile — a different path. But your pipeline is *also* a different path from every reported success: you hand-author entitlements in XcodeGen, build unsigned in CI, and re-sign on Windows. You never touch Xcode's Signing & Capabilities UI, which is where most reported behaviour comes from.

**Two Tier-0 shapes exist. Probe Test #1 selects between them.**

| | **Tier 0-A (HealthKit signs)** | **Tier 0-B (HealthKit refused)** |
|---|---|---|
| Deep backfill | Years of health + decade of photos | Decade of photos only |
| Heart / sleep / workouts / GPS routes | ✅ all of it | ❌ gone |
| Continuous physiology | ✅ | ❌ |
| Motion, place, device, network, ambient, media, calendar, contacts | ✅ | ✅ |
| Background relaunch sources | HealthKit observers + CLVisit + SLC + regions | CLVisit + SLC + regions only |
| Verdict | build as planned | still a genuinely good app; **but $99 is now near-mandatory** |

**And `com.apple.developer.healthkit.background-delivery` is a second, separate test.** It is *not* a row in Apple's capability table and is *not* configurable in the App ID portal UI — Xcode writes it silently when you tick the HealthKit capability. On iOS 15+ `enableBackgroundDelivery(for:frequency:)` hard-fails with `HKError.errorAuthorizationDenied` without it, **at runtime, not at build time**. Fallback if it fails: harvest-on-launch only, no observer wakes — which the 7-day pedometer/3-day sensor-recorder backfill windows largely absorb anyway.

---

# 1. THE MASTER MATRIX

**Legend**

| Code | Meaning |
|---|---|
| **FREE** | Works on a free Personal Team — Info.plist usage string only, or a capability in Apple's free column |
| **$99** | Requires paid Apple Developer Program; self-serve once paid |
| **APPROVAL** | Paid **plus** Apple case-by-case review (or an organization account + IRB) |
| **NO** | Impossible at any tier |
| **RELAUNCH** | System relaunches a *terminated* app to deliver |
| **YES** | Runs while backgrounded (needs a background mode, or is system-delivered) |
| **POLL** | Property readable on any background wake, but cannot wake you; the *notification* is lossy when suspended |
| **FG** | Foreground only |
| **–** / **+** / **REQ** | Watch: not needed / better with / required |

---

## 1.1 HealthKit — the deepest history on the device

**Blanket facts for every row:** Info.plist requires **both** `NSHealthShareUsageDescription` **and** `NSHealthUpdateUsageDescription` or `requestAuthorization` throws. Entitlement `com.apple.developer.healthkit`. Backfill = **entire store history, no API-imposed window** (iOS 27 beta adds a user-selectable recent-window-vs-full-history second sheet + `earliestAuthorizedSampleDate`). Background = `HKObserverQuery` + `enableBackgroundDelivery` (requires `com.apple.developer.healthkit.background-delivery`), **RELAUNCH** for `HKSampleType`s.

**Header-verified iOS 26.5 counts:** 120 `HKQuantityTypeIdentifier`, 70 `HKCategoryTypeIdentifier` (31 non-symptom + 39 symptom), 6 `HKCharacteristicTypeIdentifier`, 2 `HKCorrelationTypeIdentifier`, 2 `HKScoredAssessmentTypeIdentifier`, 1 `HKDocumentTypeIdentifier`, 9 `HKClinicalTypeIdentifier`, 84 `HKWorkoutActivityType`, 71 `HKMetadataKey`, 17 `HKObjectType` subclasses. iOS 27 beta delta = 45 symbols total: workout zones family, `menopausalState`, `bleedingAfterMenopause`, `HKCategoryValueMenopausalState`, `earliestAuthorizedSampleDate`. **Zero new quantity types in iOS 27.**

| Family (count) | Free | BG | Watch | Notes |
|---|---|---|---|---|
| Activity & fitness quantities (35) | FREE¹ | RELAUNCH | + | iPhone-alone: `stepCount`, `distanceWalkingRunning`, `flightsClimbed`. Rest are Watch/BLE. **Never sum across sources** — use `HKStatisticsCollectionQuery` |
| Body measurements (7) | FREE¹ | RELAUNCH | + | `appleSleepingWristTemperature` is Watch S8+/Ultra, absolute value (not the deviation the Health app charts) |
| Vital signs (11) | FREE¹ | RELAUNCH | REQ | except BP + `bodyTemperature` (external/manual). US `oxygenSaturation` post-Aug-2025 is computed on the *iPhone* → iPhone `sourceRevision` |
| Nutrition (39) | FREE¹ | RELAUNCH | – | iPhone/iPad only. **Empty unless a third-party logger writes** — Apple ships no food logger |
| Lab & test results (9) | FREE¹ | RELAUNCH | + | CGMs write `bloodGlucose` q1-5min. `electrodermalActivity` has **no Apple producer** |
| Mobility / gait (8) | FREE¹ | RELAUNCH | – | **iPhone**-produced (pocket/waist). Requires Health > Mobility set up. `recalibrate-estimates` is its own free-tier capability |
| Hearing & audio exposure (3) | FREE¹ | RELAUNCH | + | `environmentalAudioExposure` = **calibrated absolute dBASPL** (see §6.10). `environmentalSoundReduction` = AirPods ANC attenuation |
| UV / daylight / diving / alcohol (6) | FREE¹ | RELAUNCH | + | `timeInDaylight` needs Watch SE2/S6+ ALS. `underwaterDepth`/`waterTemperature` = Ultra. `uvExposure` has **no Apple producer** |
| Sleep-breathing + basal temp (2) | FREE¹ | RELAUNCH | + | `appleSleepingBreathingDisturbances` Watch S9+/Ultra2, watchOS 11. **Not linked from Apple's own landing page** |
| Category types, non-symptom (31→33) | FREE¹ | RELAUNCH | + | `sleepAnalysis` has 6 values incl. Core/Deep/REM (iOS 16+); iPhone-alone yields `inBed` only |
| Category types, symptoms (39) | FREE¹ | RELAUNCH | – | 100% manual. Live on a separate doc page → omitted from nearly every published enumeration |
| Characteristic types (6) | FREE¹ | **FG** | – | Not `HKSampleType` → no observer, no background. **Only family where read-denial is detectable** |
| Correlations (2) | FREE¹ | RELAUNCH | – | Authorize per **child** type. Children also exist as top-level samples → naive queries double-count |
| Workouts + 84 activity types | FREE¹ | RELAUNCH | + | `HKWorkoutActivity` nesting (iOS 17) for multisport/intervals. 3 deprecated cases still in historical data |
| **`HKWorkoutRoute` — full GPS tracks** | FREE¹ | RELAUNCH | + | **~1 Hz `CLLocation` for every outdoor workout ever, with NO CoreLocation permission and no location usage string.** See §6.1 |
| **`HKHeartbeatSeriesSample` — raw R-R** | FREE¹ | RELAUNCH | REQ | Sub-ms beat timestamps + `precededByGap`. Derive RMSSD/pNN50/LF-HF. **Absent from the Health export.** See §6.4 |
| `HKQuantitySeriesSampleQuery` | FREE¹ | RELAUNCH | + | Expands one summary sample into its per-second constituents (`cyclingPower`, `runningPower`, `underwaterDepth`) |
| ECG + full voltage waveform | FREE¹ | RELAUNCH | REQ | ~512 Hz, 30 s, ~15,360 µV samples per recording. **No special entitlement** (common misconception). ~15k callbacks — batch them |
| Audiogram (`HKAudiogramSample`) | FREE¹ | RELAUNCH | – | AirPods Pro 2+ Hearing Test writes here. iOS 18.1 `clampingRange` distinguishes true threshold from test floor/ceiling |
| State of Mind (iOS 18) | FREE¹ | RELAUNCH | + | valence −1..+1, 7 classifications, **38 labels, 18 associations** (from `HKStateOfMind.h`, not the website) |
| Scored assessments GAD-7 / PHQ-9 | FREE¹ | RELAUNCH | – | Landing page lists **no** type properties; resolve by direct URL or header |
| Vision prescription | FREE¹ | **partial** | – | **TRAP:** passing it to `requestAuthorization(toShare:read:)` fails `errorInvalidArgument`. Use `requestPerObjectReadAuthorization` — re-prompts every call |
| **Medications (iOS 26)** | FREE¹ | RELAUNCH | – | `HKMedicationDoseEvent` + `HKUserAnnotatedMedication`. **Base entitlement only.** System writes `notInteracted` rows → true adherence denominators |
| Activity summaries (rings + **goals**) | FREE¹ | **POLL** | REQ | `HKActivitySummaryType` is `HKObjectType` but **NOT** `HKSampleType` → no observer, no background delivery. Ring *goals* exist nowhere else |
| 71 `HKMetadataKey` constants | FREE¹ | RELAUNCH | – | Free second data layer riding every sample. See dump below |
| `HKDevice` / `HKSourceRevision` / `HKSourceQuery` | FREE¹ | RELAUNCH | – | Per-sample provenance: exact hardware model, OS version, writing app bundle ID |
| `HKAttachment` (iOS 17) | FREE¹ | unknown | – | Arbitrary files (PDFs, images) bound to samples. Not in the export at all |
| Clinical records (FHIR, 9 types) | ⚠ **unestablished** | partial | – | Needs `com.apple.developer.healthkit.access = ["health-records"]` + `NSHealthClinicalHealthRecordsShareUsageDescription`. **Not a row in the capability table at all** → free-tier signability unknown |
| CDA documents | FREE¹ | **FG** | – | `HKDocumentQuery` is one-shot, no update handler → no incremental sync |
| Workout zones (iOS 27 beta) | FREE¹ | RELAUNCH | + | Time-in-zone per workout per quantity type. Assume forward-only |

¹ *Conditional on Probe Test #1.*

**The 120 `HKQuantityTypeIdentifier`s (header-verified, iOS 26.5):**
```
activeEnergyBurned appleExerciseTime appleMoveTime appleStandTime appleSleepingBreathingDisturbances
appleSleepingWristTemperature appleWalkingSteadiness atrialFibrillationBurden basalBodyTemperature
basalEnergyBurned bloodAlcoholContent bloodGlucose bloodPressureDiastolic bloodPressureSystolic
bodyFatPercentage bodyMass bodyMassIndex bodyTemperature crossCountrySkiingSpeed cyclingCadence
cyclingFunctionalThresholdPower cyclingPower cyclingSpeed dietaryBiotin dietaryCaffeine dietaryCalcium
dietaryCarbohydrates dietaryChloride dietaryCholesterol dietaryChromium dietaryCopper dietaryEnergyConsumed
dietaryFatMonounsaturated dietaryFatPolyunsaturated dietaryFatSaturated dietaryFatTotal dietaryFiber
dietaryFolate dietaryIodine dietaryIron dietaryMagnesium dietaryManganese dietaryMolybdenum dietaryNiacin
dietaryPantothenicAcid dietaryPhosphorus dietaryPotassium dietaryProtein dietaryRiboflavin dietarySelenium
dietarySodium dietarySugar dietaryThiamin dietaryVitaminA dietaryVitaminB12 dietaryVitaminB6 dietaryVitaminC
dietaryVitaminD dietaryVitaminE dietaryVitaminK dietaryWater dietaryZinc distanceCrossCountrySkiing
distanceCycling distanceDownhillSnowSports distancePaddleSports distanceRowing distanceSkatingSports
distanceSwimming distanceWalkingRunning distanceWheelchair electrodermalActivity environmentalAudioExposure
environmentalSoundReduction estimatedWorkoutEffortScore flightsClimbed forcedExpiratoryVolume1
forcedVitalCapacity headphoneAudioExposure heartRate heartRateRecoveryOneMinute heartRateVariabilitySDNN
height inhalerUsage insulinDelivery leanBodyMass nikeFuel numberOfAlcoholicBeverages numberOfTimesFallen
oxygenSaturation paddleSportsSpeed peakExpiratoryFlowRate peripheralPerfusionIndex physicalEffort pushCount
respiratoryRate restingHeartRate rowingSpeed runningGroundContactTime runningPower runningSpeed
runningStrideLength runningVerticalOscillation sixMinuteWalkTestDistance stairAscentSpeed stairDescentSpeed
stepCount swimmingStrokeCount timeInDaylight underwaterDepth uvExposure vo2Max waistCircumference
walkingAsymmetryPercentage walkingDoubleSupportPercentage walkingHeartRateAverage walkingSpeed
walkingStepLength waterTemperature workoutEffortScore
```

**⚠ THREE CATEGORY TYPES EXIST IN THE SDK BUT NOWHERE IN APPLE'S DOC NAVIGATION.** Any enumeration scraped from Apple's website — which is what nearly every published HealthKit list is — silently misses them:
```
HKCategoryTypeIdentifierSleepApneaEvent           (iOS 18.0 / watchOS 11.0)
HKCategoryTypeIdentifierBleedingDuringPregnancy   (iOS 18.0 / watchOS 11.0)
HKCategoryTypeIdentifierBleedingAfterPregnancy    (iOS 18.0 / watchOS 11.0)
```

**The 71 `HKMetadataKey` constants (free second data layer — omit these and you lose real signal):**
```
DeviceSerialNumber BodyTemperatureSensorLocation HeartRateSensorLocation HeartRateMotionContext
UserMotionContext SessionEstimate HeartRateRecoveryTestType HeartRateRecoveryActivityType
HeartRateRecoveryActivityDuration HeartRateRecoveryMaxObservedRecoveryHeartRate FoodType UDIDeviceIdentifier
UDIProductionIdentifier DigitalSignature ExternalUUID SyncIdentifier SyncVersion TimeZone DeviceName
DeviceManufacturerName WasTakenInLab ReferenceRangeLowerLimit ReferenceRangeUpperLimit WasUserEntered
WorkoutBrandName GroupFitness AppleFitnessPlusCatalogIdentifier AppleFitnessPlusSession IndoorWorkout
CoachedWorkout WeatherCondition WeatherTemperature WeatherHumidity SexualActivityProtectionUsed
MenstrualCycleStart LapLength SwimmingLocationType SwimmingStrokeStyle InsulinDeliveryReason
BloodGlucoseMealTime VO2MaxTestType AverageSpeed MaximumSpeed AlpineSlopeGrade ElevationAscended
ElevationDescended FitnessMachineDuration IndoorBikeDistance CrossTrainerDistance HeartRateEventThreshold
AverageMETs AudioExposureLevel AudioExposureDuration AppleECGAlgorithmVersion DevicePlacementSide
BarometricPressure AppleDeviceCalibrated VO2MaxValue LowCardioFitnessEventThreshold
DateOfEarliestDataUsedForEstimate AlgorithmVersion SWOLFScore QuantityClampedToLowerBound
QuantityClampedToUpperBound GlassesPrescriptionDescription WaterSalinity HeadphoneGain
CyclingFunctionalThresholdPowerTestType ActivityType PhysicalEffortEstimationType MaximumLightIntensity
```

---

## 1.2 CoreMotion

| Stream | API | Permission | Free | BG | Backfill | Watch |
|---|---|---|---|---|---|---|
| Step count | `CMPedometerData.numberOfSteps` | `NSMotionUsageDescription` | FREE | POLL | **7 days** | – |
| Distance / floors ↑↓ | `.distance`, `.floorsAscended/Descended` | same | FREE | POLL | **7 days** | – |
| Average active pace | `.averageActivePace` | same | FREE | POLL | **7 days** | – |
| Current pace / cadence | `.currentPace`, `.currentCadence` | same | FREE | POLL | **NONE — live only, permanently nil on historical queries** | – |
| Walk-bout pause/resume | `CMPedometerEvent` | same | FREE | **FG** | **NONE — no `queryPedometerEvents` exists** | – |
| Motion activity (6-bit + confidence) | `CMMotionActivityManager.queryActivityStarting` | same | FREE | POLL | **7 days** | – |
| Raw accelerometer | `CMMotionManager.startAccelerometerUpdates` | **none** | FREE | partial | none | – |
| Raw gyro | `startGyroUpdates` | **none** | FREE | partial | none | – |
| Raw magnetometer (µT ×3) | `startMagnetometerUpdates` | **none** | FREE | partial | none | – |
| Attitude / gravity / userAcceleration / calibrated field / heading | `CMDeviceMotion` | **none** | FREE | partial | none | – |
| Sensor location (phone vs L/R AirPod) | `CMDeviceMotion.sensorLocation` | none | FREE | partial | none | – |
| Barometric pressure (kPa) + rel. altitude | `CMAltimeter.startRelativeAltitudeUpdates` | `NSMotionUsageDescription` | FREE | YES | none | – |
| Absolute altitude MSL + accuracy | `startAbsoluteAltitudeUpdates` | same | FREE | YES | none | – |
| **Recorded raw accel — 50 Hz while suspended OR terminated** | `CMSensorRecorder.recordAccelerometer(forDuration:)` | same | FREE | **YES** | **3 days** | – |
| AirPods head motion | `CMHeadphoneMotionManager` | `NSMotionUsageDescription` (**absent ⇒ crash**) | FREE | **FG** | none | – |
| AirPods connect/disconnect | `CMHeadphoneMotionManagerDelegate` | same | FREE | FG | none | – |
| **Headphone-derived activity (classifies the PERSON)** | `CMHeadphoneActivityManager` (iOS 18) | same | FREE | FG | **none — no historical query** | – |
| Batched 800 Hz accel / 200 Hz devicemotion | `CMBatchedSensorManager` | same | FREE | YES | none | **REQ** + active `HKWorkoutSession` |
| Water submersion / depth / water temp | `CMWaterSubmersionManager` | `NSMotionUsageDescription` | **$99**² | YES | none | REQ (Ultra) |
| Fall detection + user resolution | `CMFallDetectionManager` | `NSFallDetectionUsageDescription` | **APPROVAL** | RELAUNCH | recent past | REQ |
| Parkinsonian tremor / dyskinesia | `CMMovementDisorderManager` | `NSMotionUsageDescription` | **APPROVAL** | YES | 7 days | REQ |
| `CMOdometerData`, `CMHighFrequencyHeartRateData` | — | — | **NO producer** | — | — | — |

² `com.apple.developer.submerged-shallow-depth-and-pressure` (6 m) is a self-service Xcode capability; `...submerged-depth-and-pressure` (40 m) needs Apple approval.

**`CMLogItem.timestamp` is seconds since BOOT, not wall-clock.** `Date(timeIntervalSinceNow: sample.timestamp - ProcessInfo.processInfo.systemUptime)`. Capture the offset **once per app session and persist it** — compute it lazily at write time and a mid-session reboot silently shifts an entire block of your archive.

---

## 1.3 CoreLocation

| Stream | API | Free | BG | Backfill | Notes |
|---|---|---|---|---|---|
| **Visits (arrive/depart)** | `startMonitoringVisits()` → `CLVisit` | FREE | **RELAUNCH** | none | **On relaunch you do NOT re-call.** Works at *reduced* accuracy — no precise-location request needed |
| Significant location change (~500 m / ≥5 min) | `startMonitoringSignificantLocationChanges()` | FREE | **RELAUNCH** | none | **On relaunch you MUST re-call, or the service dies permanently.** Opposite contract to visits |
| Continuous track | `startUpdatingLocation()` | FREE | YES | none | **Dies on termination, never relaunches.** `pausesLocationUpdatesAutomatically` defaults TRUE and under WhenInUse a pause is **permanent** |
| Async stream + 11 diagnostics | `CLLocationUpdate.liveUpdates` (iOS 17/18) | FREE | partial | none | Target iOS 18+; iOS 17 build is unreliable |
| Background grant under WhenInUse | `CLBackgroundActivitySession` (iOS 17) | FREE | YES | none | Keeps you **alive**, does not **relaunch** |
| Declarative Always upgrade | `CLServiceSession(authorization:)` (iOS 18) | FREE | YES | none | Recreate immediately on background launch |
| Geofences (modern) | `CLMonitor` + `CircularGeographicCondition` | FREE | **RELAUNCH** | conditions persist by monitor name | **20 conditions max, per app, all types combined.** Only after first unlock post-reboot |
| Geofences (legacy, deprecated@27) | `CLCircularRegion` + `startMonitoring(for:)` | FREE | RELAUNCH | registrations persist | ~200 m / 20 s hysteresis (archived guide) |
| iBeacon presence | `CLMonitor.BeaconIdentityCondition` | FREE | RELAUNCH | none | Counts against the same 20 |
| iBeacon ranging (distance) | `startRangingBeacons(satisfying:)` | FREE | **FG** | none | Continuous distance; dies on suspend |
| Heading + **raw geomagnetic x/y/z** | `CLHeading` | FREE | FG | none | `trueHeading` only populated if you also run location updates |
| Course/speed/altitude/ellipsoidal/**floor**/provenance | `CLLocation` properties | FREE | RELAUNCH | none | `isSimulatedBySoftware` = data-integrity gate. `CLFloor.level` = free vertical context in mapped venues |
| Historical locations | `requestHistoricalLocations` | FREE | ? | **YES — the only CL backfill** | **watchOS 9.0 ONLY.** No iOS availability. Effectively undocumented |
| Reverse geocode (legacy) | `CLGeocoder` | FREE | FG | n/a | **Deprecated iOS 26.** `CLPlacemark` deprecated iOS 27 |
| Reverse geocode (modern) | `MKReverseGeocodingRequest` (iOS 26) | FREE | FG | n/a | Rate limit **undocumented**; observed server ceiling 50 req / 60 s |
| **Stable place identity** | `MKMapItem.Identifier` + `MKMapItemRequest` | FREE | FG | n/a | Archivable string. **This is what makes a multi-year place log tractable.** See §6.18 |
| POI search / autocomplete | `MKLocalSearch`, `MKLocalSearchCompleter` | FREE | FG | n/a | Turns a visit centroid into "Starbucks on Preston" |
| Portable place descriptor | `GeoToolbox.PlaceDescriptor` (iOS 26) | FREE | FG | n/a | `serviceIdentifier(for:)` = the documented seam to a **non-Apple** place service (OSM/Overture) |
| Server-initiated location query | `CLLocationPushServiceExtension` | **$99** | RELAUNCH | none | `com.apple.developer.location.push` + APNs. ~360 pushes/24 h. Wrong tool here |

**Info.plist:** `NSLocationWhenInUseUsageDescription` (required), `NSLocationAlwaysAndWhenInUseUsageDescription` (for Always), `NSLocationTemporaryUsageDescriptionDictionary`, optional `NSLocationDefaultAccuracyReduced`. Ship the deprecated `NSLocationAlwaysUsageDescription` too — Apple's own docs contradict themselves on which key `requestAlwaysAuthorization()` reads.

**FATAL:** `allowsBackgroundLocationUpdates = true` without `UIBackgroundModes` containing `location` is, verbatim, "a fatal error that terminates the app."

---

## 1.4 Device & system state — **zero backfill anywhere**

Every row here starts empty at first launch. There is no historical store. Sampling cadence *is* the data quality.

| Stream | API | Free | BG | Notes |
|---|---|---|---|---|
| Battery % | `UIDevice.batteryLevel` | FREE | POLL | **Quantized to 5% since iOS 17** (was 1%). ~20 events per discharge |
| Battery state | `.batteryState` (4 cases) | FREE | POLL | No wired/MagSafe/Qi distinction, no wattage, **no health/cycle count** |
| Low Power Mode | `ProcessInfo.isLowPowerModeEnabled` | FREE | POLL | Notification is legacy-named `NSProcessInfoPowerStateDidChange` |
| Thermal state (4 levels) | `ProcessInfo.thermalState` | FREE | POLL | **No numeric temperature exists anywhere on iOS** |
| CPU cores / **active** cores | `processorCount` / `activeProcessorCount` | FREE | YES | `activeProcessorCount` dropping = free core-parking / throttle detector |
| RAM installed | `physicalMemory` | FREE | YES | Device fingerprint |
| Own memory headroom | `os_proc_available_memory()` | FREE | POLL | Snapshot only — Apple says never cache it |
| Memory pressure | `DispatchSource.makeMemoryPressureSource` | FREE | POLL | System-wide, unlike the UIApplication notification |
| Disk free/total (4 flavours) | `volumeAvailableCapacity*` keys | FREE | POLL | `ForImportantUsage` counts **purgeable** space and can exceed the honest number |
| Uptime / reboot | `systemUptime` + `sysctl kern.boottime` | FREE | POLL | ⚠ `systemUptime` counts **awake time only**. Apple DTS: not a reliable restart detector alone |
| Screen brightness | `UIScreen.brightness` | FREE | **FG** | With auto-brightness on, this **is** an indirect ALS readout, zero permission |
| Screen capture / mirroring | `UIScreen.isCaptured` → `UITraitCollection.sceneCaptureState` (iOS 27) | FREE | FG | **`isCaptured` deprecated in iOS 27** |
| Screenshot taken | `userDidTakeScreenshotNotification` | FREE | **FG** | **Only while YOUR app is on screen.** No cross-app screenshot log exists |
| Display characteristics + EDR headroom | `UIScreen.*` | FREE | FG | `maximumFramesPerSecond` distinguishes ProMotion |
| Device orientation (7 states) | `UIDevice.orientation` | FREE | FG | Returns `.unknown` until `beginGeneratingDeviceOrientationNotifications()`. `.faceDown` = deliberate disengagement |
| Proximity | `UIDevice.proximityState` | FREE | FG | **Enabling it BLANKS THE SCREEN** — not passively usable |
| Output volume | `AVAudioSession.outputVolume` (KVO) | FREE | **YES** | No mic permission. 1/16 steps |
| **Audio route + device NAMES** | `AVAudioSession.currentRoute` | FREE | **YES** | "Zach's AirPods Pro", "Honda HFT". 22 port types. See §6.9 |
| Other app playing audio | `isOtherAudioPlaying`, `secondaryAudioShouldBeSilencedHint` | FREE | YES | Never *which* app. `interruptionNotification` reveals calls/Siri/alarms |
| Lock proxy (data protection) | `protectedDataWillBecomeUnavailable` | FREE | POLL | ⚠ Needs a passcode; lags 10-40 s. Apple DTS: "no supported way to track device lock state" |
| Per-scene Face ID gating (iOS 18) | `UIScene.SystemProtectionManager` | FREE | FG | **Not** a lock-state API — reports *your app's* protection |
| App lifecycle / scene activation | `UIApplication.State` / `UIScene.ActivationState` | FREE | POLL | **iOS 27: scene-based lifecycle is MANDATORY or the app fails to launch** |
| 20 accessibility settings + 21 notifications | `UIAccessibility.*` | FREE | POLL | `isGuidedAccessEnabled` = deliberate focus session |
| UI traits (dark mode, text size, contrast) | `UITraitCollection` | FREE | FG | **Auto dark mode = free daylight sensor.** See §6 runners-up |
| System resource pressure (iOS 27 beta) | `systemPrefersReducedResourceUsage` | FREE | POLL | Broader/earlier than thermal or LPM |
| Time zone change | `NSSystemTimeZoneDidChange` | FREE | POLL | **Permission-free travel/jet-lag detector — the only geographic signal here** |
| Locale / region / calendar | `NSCurrentLocaleDidChange` | FREE | POLL | Fingerprint, not a series |
| Network path (see §1.5) | `NWPathMonitor` | FREE | YES | |
| Background App Refresh state | `UIApplication.backgroundRefreshStatus` | FREE | POLL | **Log this as a data-quality channel** |
| Own notifications + **settings** | `UNUserNotificationCenter` | FREE | POLL | Own app only. `getNotificationSettings` needs **no prompt** and is an interruption-tolerance fingerprint |
| Device model code | `sysctlbyname("hw.machine")` | FREE | YES | `UIDevice.model` is useless ("iPhone"); `UIDevice.name` is generic since iOS 16 without a special entitlement |
| Focus on/off (bool only) | `INFocusStatusCenter` | **$99** | partial | Needs Communication Notifications capability. **And it only gives a bool — use Shortcuts instead (§1.9)** |

---

## 1.5 Network, radio, accessories

| Stream | API | Free | BG | Backfill |
|---|---|---|---|---|
| Path status / interface type (5 cases) | `NWPath.status`, `usesInterfaceType` | FREE | YES | none |
| **BSD interface names** | `NWPath.availableInterfaces[].name` | FREE | YES | none |
| Expensive / constrained / **ultraConstrained** (iOS 26) | `NWPath.isExpensive/.isConstrained/.isUltraConstrained` | FREE | YES | none |
| **Link quality** (iOS 26, 4 levels) | `NWPath.linkQuality` | FREE | YES | none |
| Unsatisfied reason (incl. `.vpnInactive`, `.localNetworkDenied`) | `NWPath.unsatisfiedReason` | FREE | YES | none |
| Gateways / IPv4/IPv6/DNS support / local endpoint | `NWPath.*` | FREE | YES | none |
| **Per-interface byte + packet counters** | `getifaddrs()` → `if_data` | FREE | POLL | **cumulative since boot** |
| Own-app data volume (supported) | MetricKit `MXNetworkTransferMetric` → iOS 27 `MetricResult` | FREE | **YES** | ~7 days of payloads, install-forward |
| **Per-request network lab** | `URLSessionTaskTransactionMetrics` | FREE | YES | none |
| Radio access technology (13 constants) | `serviceCurrentRadioAccessTechnology` | FREE | POLL | none |
| Which SIM carries data | `dataServiceIdentifier` | FREE | POLL | none |
| Per-app cellular restriction | `CTCellularData.restrictedState` | FREE | POLL | none |
| Carrier name / MCC / MNC | `CTCarrier` | **DEAD** | — | Returns `"--"` / `65535` since iOS 16.4 SDK |
| BLE advertisers (crowd proxy) | `CBCentralManager.scanForPeripherals` | FREE | **FG for nil-services** | none |
| BLE connected devices (incl. other apps') | `retrieveConnectedPeripherals(withServices:)` | FREE | partial | none |
| Bluetooth radio state / authorization | `CBManagerState`, `CBManager.authorization` | FREE | POLL | none |
| **Classic-BT devices by NAME** | `AVAudioSession.currentRoute` | FREE | **YES** | none |
| MFi wired accessories | `EAAccessoryManager` | FREE | YES | none |
| Accessory pairing without prompts | `AccessorySetupKit` (iOS 18) | FREE | FG | none |
| UWB distance + direction | `NearbyInteraction` | FREE | partial | none |
| **Bonjour/mDNS LAN device enumeration** | `NWBrowser` / `NetworkBrowser` (iOS 26) | FREE | FG | none |
| Apple Watch reachability + its own path | `WCSession.isReachable`; watchOS `NWPathMonitor` | FREE | partial | none |
| Wi-Fi SSID / BSSID / security | `NEHotspotNetwork.fetchCurrent` | **$99** | partial | none |
| Wi-Fi signal strength, autoJoin, chosenHelper | `NEHotspotHelper` callback | **APPROVAL** | YES | none |
| Wi-Fi Aware (iOS 26) | `WiFiAware` framework | **$99** | ? | none |
| Own-app VPN config state | `NEVPNManager` | **$99** | YES | none |
| Arbitrary Bonjour types / IP multicast | `com.apple.developer.networking.multicast` | **APPROVAL** | FG | none |

**Info.plist:** `NSBluetoothAlwaysUsageDescription` (BLE), `NSLocalNetworkUsageDescription` + `NSBonjourServices` array (mDNS), `NSNearbyInteractionUsageDescription` (UWB), `UISupportedExternalAccessoryProtocols` (MFi).

**`getifaddrs` counters are `UInt32` and wrap at 4 GiB** — a daily event on Wi-Fi, not a corner case. `if_data64` has "no supported way to get that value on Apple platforms." A decrease means either a wrap (add 2³²) or a reboot; disambiguate with `systemUptime`.

---

## 1.6 Personal data stores

| Stream | API | Permission | Free | BG | Backfill |
|---|---|---|---|---|---|
| Calendar events (full read) | `EKEventStore.requestFullAccessToEvents` | `NSCalendarsFullAccessUsageDescription` | FREE | POLL | **complete-as-synced** |
| **Attendees → dated social graph** | `EKCalendarItem.attendees` → `EKParticipant` | same (+`NSContactsUsageDescription` to resolve) | FREE | POLL | complete |
| Reminders + `completionDate` | `requestFullAccessToReminders` | `NSRemindersFullAccessUsageDescription` | FREE | POLL | complete until Reminders GCs |
| Calendar structure (`EKSource`, `EKCalendar`) | `.sources`, `.calendars(for:)` | same | FREE | POLL | current only |
| Change notification | `EKEventStore.EventStoreChanged` | same | FREE | FG | **no token, no payload — snapshot+diff yourself** |
| Contacts (all 30 keys) | `CNContactStore.enumerateContacts` | `NSContactsUsageDescription` | FREE | POLL | current state |
| Contact **notes** | `CNContactNoteKey` | same | ⚠ **request form** | POLL | current |
| Groups / containers | `CNGroup`, `CNContainer` | same | FREE | POLL | current |
| **Contacts change history (12 event classes)** | `CNChangeHistoryFetchRequest` | same | FREE | POLL | **forward-only from your first token** |
| Photos: 20 asset properties + GPS | `PHAsset` | `NSPhotoLibraryUsageDescription` | FREE | POLL | **complete library, decade+** |
| Photo file facts, `dataSize` (iOS 27) | `PHAssetResource` (13 types) | same | FREE | POLL | complete |
| Full EXIF/GPS/TIFF | `requestImageDataAndOrientation` + ImageIO | same | FREE | POLL | complete |
| 21 smart albums (screenshots, screen recordings, selfies, RAW, spatial…) | `PHAssetCollectionSubtype` | same | FREE | POLL | complete |
| Live change observation | `PHPhotoLibraryChangeObserver` | same | FREE | FG | none |
| **Persistent change token** | `fetchPersistentChanges(since:)` (iOS 16) | same | FREE | POLL | forward from token; library itself is fully historical |
| Zero-permission photo read | `PHPickerViewController` | **NONE** | FREE | FG | user-selected only |
| Music: playCount, skipCount, rating, lastPlayed | `MPMediaQuery` / `MPMediaItem` | `NSAppleMusicUsageDescription` | FREE | POLL | **lifetime counters, no per-play timestamps** |
| Now playing (Music app only) | `MPMusicPlayerController.systemMusicPlayer` | same | FREE | POLL | none |
| MusicKit library + `playCount`/`lastPlayedDate` | `MusicLibraryRequest<Song>` | same | FREE | POLL | counters only |
| Recently played (~25 rolling) | `MusicRecentlyPlayedRequest` | same | FREE | POLL | short window |
| **Arbitrary folder tree, persistent** | `UIDocumentPickerViewController` + security-scoped bookmark | **NONE** | FREE | POLL | complete, survives reboot |
| Speech-to-text over files & live | `SFSpeechRecognizer`, `SFSpeechURLRecognitionRequest` | `NSSpeechRecognitionUsageDescription` (+`NSMicrophoneUsageDescription` live only) | FREE | partial | complete over any reachable audio |
| Modern speech + **`SpeechDetector` VAD** | `SpeechAnalyzer` (iOS 26) | same | FREE | partial | complete |
| Journaling Suggestions (15 item types incl. **third-party now-playing**) | `JournalingSuggestionsPicker` | picker = consent | **$99** | FG | short recent window |
| Keyboard input capture | Custom keyboard + `RequestsOpenAccess` | user toggles Full Access | FREE | YES | forward-only |
| Clipboard classification **without the paste banner** | `UIPasteboard.detectPatterns(for:)` | none | FREE | **FG** | none |
| Call count / direction / duration | `CXCallObserver` | none | FREE | partial | **forward-only, no numbers, no log** |

**`EKEvent.travelTime` DOES NOT EXIST.** Zero hits for `/travel/i` across the entire EventKit symbol index. `EKStructuredLocation` has exactly three properties: `title`, `geoLocation`, `radius`. The Calendar app's Travel Time field has no public API. Plan without it.

---

## 1.7 Ambient environment

| Stream | API | Permission | Free | BG | Backfill |
|---|---|---|---|---|---|
| **Ambient sound classification, 303 labels** | `SNClassifySoundRequest(.version1)` + `SNAudioStreamAnalyzer` | `NSMicrophoneUsageDescription` | FREE | partial | none |
| Relative sound level (dBFS) | `AVAudioRecorder.averagePower(forChannel:)` | same | FREE | YES | none |
| **Absolute A-weighted dBASPL** | HK `environmentalAudioExposure` | `NSHealthShareUsageDescription` | FREE¹ | RELAUNCH | **full store history** |
| ANC attenuation (dB) | HK `environmentalSoundReduction` | same | FREE¹ | RELAUNCH | full |
| Headphone dose | HK `headphoneAudioExposure` | same | FREE¹ | RELAUNCH | full |
| **Time in daylight (lux-derived)** | HK `timeInDaylight` | same | FREE¹ | RELAUNCH | full · Watch REQ |
| Water temp / underwater depth | HK `waterTemperature`, `underwaterDepth` | same | FREE¹ | RELAUNCH | full · Ultra |
| Barometric pressure | `CMAltimeter` | `NSMotionUsageDescription` | FREE | YES | none |
| Magnetic field (EMF fingerprint) | `CMMagnetometerData` | **none** | FREE | partial | none |
| Scene lumens + **colour temperature (K)** | `ARLightEstimate` | `NSCameraUsageDescription` | FREE | **FG** | none |
| Directional light + spherical harmonics | `ARDirectionalLightEstimate` | same | FREE | FG | none |
| ISO / exposure / aperture as light proxy | `AVCaptureDevice` KVO | same | FREE | FG | none |
| Screen brightness as ALS proxy | `UIScreen.brightness` | **none** | FREE | FG | none |
| **Weather + air quality + pollen + 1940→present archive** | **Open-Meteo** HTTP JSON | `NSLocationWhenInUse` (coords only) | **FREE, keyless** | YES | **FULL, back to 1940** |
| Weather (Apple) | `WeatherKit` | same | **$99** | YES | climatology only |
| SensorKit: 21 sensors (lux+chromaticity, PPG, ECG raw, keyboard metrics, device usage, speech metrics, face metrics, wrist temp, odometer…) | `SRSensorReader` / `SRReader` (iOS 27) | `NSSensorKitUsageDescription` + per-sensor `NSSensorKitUsageDetail` | **APPROVAL** | YES | 7 d rolling **minus a 24 h hold** (7 d for faceMetrics) |

**SoundAnalysis environment-relevant subset** (of 303 — full roster in `SoundML/SoundType.swift`):
```
silence speech whispering snoring breathing coughing sneeze laughter typing typing_computer_keyboard
air_conditioner mechanical_fan microwave_oven blender vacuum_cleaner hair_dryer printer toilet_flush
water_tap_faucet sink_filling_washing bathtub_filling_washing dishes_pots_pans frying_food chopping_food
door door_bell door_slam knock keys_jangling traffic_noise car_passing_by siren police_siren
rain raindrop thunderstorm thunder wind wind_rustling_leaves ocean sea_waves
bird_chirp_tweet cricket_chirp dog_bark cat_meow music television
```

**`AVAudioSession.Mode.measurement` is load-bearing.** Without it, iOS applies AGC and dynamics processing to the input, and a quiet room converges toward the same meter reading as a loud one. That one line separates a usable ambient-noise series from noise.

---

## 1.8 Screen time & app usage — three routes, three tiers

| Route | Free | What you get | Backfill | Verdict |
|---|---|---|---|---|
| **iOS 26 Shortcuts action: `Screen Time > Get App & Website Data`** | **FREE** | per-app + per-website usage | **~4 weeks (whatever Screen Time retains)** | **The Tier 0 winner — routes entirely around Family Controls.** Verify consent UX on device |
| Shortcuts `App` trigger: *Is Opened* / *Is Closed* → background App Intent | **FREE** | exact session start/end per app | none, forward-only | Manual: 2 automations per app, hand-built. *Is Closed* unreliable |
| `DeviceActivity` / `FamilyControls` / `ManagedSettings` | **$99 (dev)** | totalActivityDuration, numberOfPickups, numberOfNotifications, firstPickup, longestActivity, totalPickupsWithoutApplicationActivity, per-category, per-web-domain, per-device | ~30 d rolling from authorization | **Render-only** unless you threshold-count. See §3 |
| iOS 26.4 `DeviceActivityData.activityData(filteredBy:using:)` + `FamilyActivityData.installedApplications` | **$99** + second entitlement | real exportable numbers **and** bundleIdentifier↔token mapping | ~30 d | ⚠ **EU-region-gated at runtime.** Assume it throws in Texas |
| Mac + `aw-import-screentime` reading `~/Library/Biome/streams/restricted/App.InFocus/remote/<device_id>/` | needs a **Mac** | per-app focus **events with timestamps**, finer than Apple's own UI | whatever Biome retains | **Highest fidelity. Violates the no-Mac constraint.** This converts "impossible" into "priced at one Mac mini" |
| SensorKit `SRSensor.deviceUsageReport` | **APPROVAL** | per-category usage, screen wakes, unlocks, notifications | 7 d − 24 h | The only sanctioned in-process API; unreachable |

---

## 1.9 Shortcuts & App Intents — the collection channel with no entitlements

**The architecture insight: every runtime permission belongs to the SHORTCUTS APP, not to yours.** Your app ships **zero** Info.plist usage strings for any of these. Location "Always" for geofences, Wallet access for transactions, NFC hardware — all held by Shortcuts. Your app just receives the payload via an `AppIntent`.

**Complete iOS 26 iPhone trigger inventory — 21 triggers. Anything not on this list is not a trigger.**

| Category | Triggers | Run Immediately |
|---|---|---|
| Event | Time of Day (incl. sunrise/sunset ± 4 h), Alarm (snoozed/stopped), Sleep (wind-down/bedtime/waking), Apple Watch Workout (start/end, type-filtered), Sound Recognition | ✅ all |
| Travel | Arrive, Leave, **Before I Commute**, CarPlay (connect/disconnect) | ✅ except **Before I Commute — the only one that cannot** |
| Communication | Email (sender/subject/account/recipient), Message (sender/contains) | ✅ |
| Transaction | Transaction (**physical NFC tap only**) | ✅ |
| Setting | Wi-Fi (join), Bluetooth (connect — **this is the AirPods trigger**), Focus (on/off), Low Power Mode, Battery Level (threshold), Charger (connect/disconnect), NFC (tag ID only), **App (Is Opened / Is Closed)**, Airplane Mode | ✅ all |

**Explicit non-triggers:** screen brightness, display sleep/wake, screen lock/unlock, orientation, silent switch, volume, cellular data, VPN, calendar event start, reminder due, contact called, photo taken, step count, heart rate. "Do Not Disturb" is not its own trigger — it is one option inside Focus. There is no "After I Commute."

| Handoff mechanism | API | Free | BG |
|---|---|---|---|
| Silent background intent | `AppIntent` + `supportedModes: IntentModes = [.background]` (iOS 26) | FREE | **YES, ~30 s budget** |
| **Focus-change push channel** | `SetFocusFilterIntent` | FREE | YES |
| Zero-config voice/Spotlight | `AppShortcutsProvider` | FREE | YES |
| Control Center / Lock Screen / Action Button | `ControlWidget` + `ControlWidgetButton(action:)` | FREE | YES (inactive while locked) |
| Instant capture while locked | `LockedCameraCapture` + `CameraCaptureIntent` (iOS 18) | FREE | partial |
| Session UI from background | `LiveActivityIntent` + ActivityKit | FREE | partial |
| Interactive result UI | `SnippetIntent` (iOS 26) | FREE | YES |
| File handoff (no intent at all) | Shortcuts "Append to Text File" → iCloud/Files | FREE | YES |

**`openAppWhenRun` is deprecated and errors in an extension.** Use `supportedModes`. Read `IntentSystemContext.preciseTimestamp` on Watch Ultra Action Button presses — that's the moment of the press, not the moment your code ran.

---

## 1.10 External enrichment

| Source | Cost | What | Backfill |
|---|---|---|---|
| **Open-Meteo forecast + archive + air-quality** | **$0, keyless, no account** | temp, apparent temp, humidity, dewpoint, surface+sea-level pressure, cloud cover (low/mid/high), visibility, wind at 10/80/120/180 m, gusts, precip/rain/snow, weather code, UV index, sunshine + daylight duration, shortwave/direct/diffuse radiation, CAPE, VPD, evapotranspiration, soil temp+moisture at depth; PM2.5, PM10, O₃, NO₂, SO₂, CO, AOD, dust, EU+US AQI, **birch/grass/ragweed pollen** | **hourly, 1940 → present, any coordinate** |
| WeatherKit | $99 | current, minute precip, hourly/daily to 10 d, alerts, pressure trend, sun/moon | climatology only |

Open-Meteo free limits: 600/min, 5,000/hr, 10,000/day, 300,000/month — *above* WeatherKit's 500k/mo, with no gate. CC BY 4.0 non-commercial. Self-hostable via Docker.

---

# 2. TIER 0 — THE ZERO-ENTITLEMENT SURFACE

**This is what ships on day one for $0.** Everything here needs only an Info.plist usage string, a runtime prompt, or a capability Apple's own table marks available to a free Personal Team.

## 2.1 Info.plist — the complete Tier 0 key set

```xml
NSHealthShareUsageDescription            <!-- required, both, or requestAuthorization throws -->
NSHealthUpdateUsageDescription
NSMotionUsageDescription                 <!-- ABSENT = CRASH on CMPedometer/CMAltimeter/
                                              CMSensorRecorder/CMHeadphoneMotionManager -->
NSLocationWhenInUseUsageDescription
NSLocationAlwaysAndWhenInUseUsageDescription
NSLocationAlwaysUsageDescription         <!-- deprecated but Apple's own docs demand it -->
NSMicrophoneUsageDescription
NSSpeechRecognitionUsageDescription
NSCameraUsageDescription
NSBluetoothAlwaysUsageDescription
NSLocalNetworkUsageDescription  +  NSBonjourServices[]
NSCalendarsFullAccessUsageDescription     <!-- NOT the write-only variant -->
NSRemindersFullAccessUsageDescription
NSContactsUsageDescription
NSPhotoLibraryUsageDescription
NSAppleMusicUsageDescription
NSNearbyInteractionUsageDescription
PHPhotoLibraryPreventAutomaticLimitedAccessAlert = true
UIBackgroundModes = [location, processing, fetch, audio, bluetooth-central]
BGTaskSchedulerPermittedIdentifiers = [com.you.app.refresh, com.you.app.process]
```

## 2.2 Entitlements Tier 0 may claim (free column of Apple's table)

```xml
com.apple.developer.healthkit                       <!-- Probe Test #1 -->
com.apple.developer.healthkit.background-delivery   <!-- Probe Test #2 -->
com.apple.security.application-groups = [group.com.you.app]   <!-- Probe Test #3 -->
keychain-access-groups
<!-- plus auto: application-identifier, get-task-allow, com.apple.developer.team-identifier -->
```

## 2.3 What Tier 0 actually collects

**Deep historical, available on first launch, no background dependency:**
- Entire HealthKit store — 213 type identifiers, every workout, every GPS route, every ECG, every heartbeat series¹
- Entire photo library metadata — timestamps, GPS, EXIF, screenshots, screen recordings, selfies, burst identity, edit history
- All calendars, all events with attendees, all reminders with completion timestamps
- All contacts
- 7 days of steps/distance/floors/pace + 7 days of motion-activity classification
- 3 days of 50 Hz raw accelerometer recorded while your app was suspended or terminated
- ~4 weeks of per-app Screen Time (via the iOS 26 Shortcuts action)
- Music library with lifetime play/skip counts
- Since-boot per-interface byte counters
- Any folder tree the user picks once

**Continuous, background-capable:**
- Location: visits (relaunch), significant changes (relaunch), 20 rotating geofences (relaunch), continuous track while resident
- HealthKit observer queries with background delivery¹ (relaunch)
- Audio route changes — AirPods/car/HomePod by name
- Network path changes — Wi-Fi↔cellular, expensive, constrained, link quality
- Barometric pressure at ~1 Hz
- Sound classification, duty-cycled
- Every polled device/system property on every wake

**Event-driven via Shortcuts, needing nothing from your app:**
- Wi-Fi join, Bluetooth connect, NFC tag scan, Apple Pay tap, charger, battery threshold, alarm, sleep schedule, workout, CarPlay, app open/close, arrive/leave, message/email arrival, Focus change, sound recognition

**Enrichment:** full weather + air quality + pollen history back to 1940 for every coordinate you ever logged.

¹ *Tier 0-B: strike the HealthKit rows. What remains — photos, calendar, contacts, motion 7 d, sensor recorder 3 d, location, device, network, ambient, Shortcuts, weather — is still a substantial app. It is not, however, a health app.*

---

# 3. TIER 1 — WHAT $99 BUYS

| Capability | Entitlement | What it unlocks | Worth $99 for a personal QS app? |
|---|---|---|---|
| **1-year provisioning profiles** | (membership property) | **Kills the 7-day re-sign treadmill.** Removes the single largest cause of silent data loss | **YES. This alone justifies it.** |
| **Family Controls (development)** | `com.apple.developer.family-controls` | DeviceActivity + ManagedSettings + FamilyActivityPicker on your own device. **Self-serve — no Apple review for a development profile, and sideloading uses a development profile** | **Qualified yes — read the three-part note below** |
| Screen Time export (iOS 26.4) | `...family-controls.app-and-website-usage` | `DeviceActivityData.activityData()` in-process + `FamilyActivityData.installedApplications` (bundleID↔token) | ⚠ **EU-region-gated at runtime. Assume it throws in Dallas.** Do not pay for this |
| Access WiFi Information | `com.apple.developer.networking.wifi-info` | SSID + BSSID + security type | **Marginal.** Bonjour device-set hashing (§6.15) is a better place fingerprint anyway |
| WeatherKit | `com.apple.developer.weatherkit` | Apple weather, 500k calls/mo | **NO.** Open-Meteo is free, keyless, and has a 1940-present archive WeatherKit lacks |
| Journaling Suggestions | `com.apple.developer.journal.allow` | 15 item types incl. **`GenericMedia` — the ONLY sanctioned read of third-party now-playing (Spotify, Overcast)** | **Yes if third-party media matters.** Nothing else on iOS gives it |
| Push Notifications | `aps-environment` | Silent push as a background wake source | **Useful but not decisive** — you'd need a server, and location relaunch already covers it |
| iCloud / CloudKit | `com.apple.developer.icloud-*` | Cross-device sync of your own data | **No** — you own a VM; sync there |
| Communication Notifications | `com.apple.developer.usernotifications.communication` | `INFocusStatusCenter.isFocused` — **a single bool, never which Focus** | **NO.** Shortcuts Focus automations name the Focus for free |
| Siri (legacy SiriKit) | — | `INExtension`. **App Intents needs no entitlement at any tier** | No |
| NFC Tag Reading | `com.apple.developer.nfc.readersession.formats` | In-app NFC | **No** — the Shortcuts NFC trigger is free and better |
| Wallet / Apple Pay | — | — | No — the Shortcuts Transaction trigger is free |
| Network Extensions / Personal VPN / Multipath / Hotspot / 5G Slicing / App Attest / Associated Domains / Sign in with Apple / Group Activities / Push to Talk / Sensitive Content Analysis / Time Sensitive Notifications / Media Device Discovery / Sustained Execution | various | — | No |
| Water submersion (6 m) | `com.apple.developer.submerged-shallow-depth-and-pressure` | Depth, water pressure, **water temperature** on Watch Ultra | Only if you own an Ultra and dive |

### The Family Controls verdict, precisely

Three facts, all of which must be held at once:

1. **The development entitlement is self-serve.** Apple's own "Configuring Family Controls" page: "Xcode automatically updates your app target's entitlements file… and you can access the entitlement through the Apple Developer Program during development." Tick the box, build to your device. No form, no wait. The approval-gated request at `developer.apple.com/contact/request/family-controls-distribution` is required only for TestFlight/App Store — and must be filed separately for *every* extension bundle ID.

2. **The `DeviceActivityReportExtension` cannot export a single byte.** Apple, verbatim: "This sandbox prevents your extension from making network requests or moving sensitive content outside the extension's address space." Empirically confirmed: App Group `UserDefaults`, App Group file writes, Core Data, `NotificationCenter` and Darwin notifications **all fail**; the extension gets its own private `UserDefaults` store even with an identical `suiteName`. You get a beautiful in-app dashboard you cannot back up, export, or compute on.

3. **The working mechanism is threshold-counting via `DeviceActivityMonitor`, which is NOT sandboxed.** Register `DeviceActivityEvent`s with `threshold: DateComponents` and count `eventDidReachThreshold` callbacks, writing through to an App Group on every callback. The published working recipe: **12 two-hour schedules tiling the day × 24 events each at 5-minute increments (5, 10, …, 120 min) ⇒ ~5-minute resolution across a full day, consuming 12 of your ~20 activity budget.** Limits are undocumented (20 activities, 15-min–1-week interval are community-derived; the events-per-activity ceiling has no published figure from anyone). Reliability is acknowledged-bad: an Apple Frameworks Engineer confirmed in Nov 2024 that thresholds fire in bunches because the extension is terminated and iOS 17+ retries queued events; ~5-6 MB memory ceiling with Jetsam kills; open 26.x threads report `intervalDidStart` never firing at all on 26.3.1.

**Net:** $99 buys you Screen Time as **lossy threshold-counted numbers**, not clean exports. **Compare that against the Tier 0 route — the iOS 26 Shortcuts `Get App & Website Data` action, which is free, needs no entitlement, and carries ~4 weeks of retroactive history that threshold-counting can never produce.** Test the free route first. If it delivers, Family Controls is not worth the money on its own merits — the $99 is worth paying for the 1-year profile.

### The cheapest useful free signal Family Controls also gives you

`DeviceActivityMonitor.intervalDidStart(for:)` fires only when the person **actually uses the device** within the interval ("the system only invokes this method when the device is in use"). A chain of short repeating schedules gives you a coarse device-active/idle timeline with zero threshold arithmetic and zero app selection. Everyone reaches for `eventDidReachThreshold`; almost nobody uses this.

---

# 4. TIER 2 — APPROVAL-GATED

## 4.1 SensorKit — do not bother

**Three independent gates, each fatal alone:**
1. **Organization account with a D-U-N-S number.** "Individual accounts are not accepted." An individual ADP account is rejected before technical review.
2. **Approved research study.** Development entitlement needs a research proposal + a signed SensorKit Addendum emailed to `sensorkitrequest@apple.com`. Distribution additionally needs an IRB/Ethics letter, an Informed Consent Form, signed Collaborator Agreements, and Apple committee review. Reported: 5-7 days to first response, **8-14 weeks to grant**.
3. **Code signing.** Explicit App ID with the sensor reader under Additional Capabilities, manual provisioning profile, manual signing style. A free Personal Team can do none of these, and `amfid` validates the entitlement at launch — the system **closes** an app whose signature lacks it.

Even on success: **a 24-hour holding period on all data (7 days for `faceMetrics`), and a fetch whose range overlaps it returns ZERO results — silently, not as an error.** Real-time SensorKit is impossible by design.

**What you'd be giving up:** true lux + CIE chromaticity, raw PPG, raw streaming ECG, keyboard metrics (typing speed, typo/autocorrect rates, per-key touch distances), speech metrics from Siri and calls, device/messages/phone usage reports, face metrics, archival gyro. Everything else has a free substitute:

| SensorKit sensor | Free substitute |
|---|---|
| `ambientPressure` | `CMAltimeter.startRelativeAltitudeUpdates` → `CMAltitudeData.pressure` |
| `pedometerData` | `CMPedometer.queryPedometerData` (identical type, 7-day backfill) |
| `visits` | `CLVisit` via `startMonitoringVisits()` — and it relaunches your app |
| `accelerometer` | `CMSensorRecorder` (50 Hz, 3 days, no entitlement) |
| `heartRate` | HealthKit `heartRate` (coarser) + `HKHeartbeatSeriesSample` (raw R-R, arguably better) |
| `electrocardiogram` | `HKElectrocardiogram` with full ~512 Hz voltage — user-initiated only |
| `wristTemperature` | HK `appleSleepingWristTemperature` |
| `ambientLightSensor` | HK `timeInDaylight` (Watch ALS-derived) + `ARLightEstimate` + `UIScreen.brightness` |
| `onWristState` | none direct; infer from HR sample cadence |
| `deviceUsageReport` | iOS 26 Shortcuts Screen Time action |
| `keyboardMetrics`, speech metrics, `faceMetrics`, `mediaEvents`, `messagesUsageReport`, `photoplethysmogram`, `rotationRate` | **none** |

**Verdict: no. Not reachable, not worth pursuing, and 8 of 21 sensors have adequate free substitutes.**

## 4.2 Other approval-gated items

| Item | Entitlement | Odds | Bother? |
|---|---|---|---|
| Fall detection | `com.apple.developer.health.fall-detection` | Low for a personal app | **No** — HK `numberOfTimesFallen` is free (drops dismissed falls) |
| Movement disorder (tremor/dyskinesia) | Apple-granted + mandatory verbatim disclosure UI + clinically-diagnosed-users-only clause | ~0 | **No** |
| `NEHotspotHelper` | `com.apple.developer.networking.HotspotHelper` | **~0.** Apple DTS: "The vast majority of requests are rejected… only useful for hotspot integration… not… Wi-Fi based location." Wi-Fi-based location is *named as disqualifying* | **No** |
| IP multicast / arbitrary Bonjour | `com.apple.developer.networking.multicast` | Moderate | **No** — declare your service types in `NSBonjourServices` instead |
| Full 40 m dive depth | `com.apple.developer.submerged-depth-and-pressure` | Moderate | No — the shallow 6 m capability is self-serve |
| Severe vehicular crash | `com.apple.developer.severe-vehicular-crash-event` | Low | No |
| Contact notes | `com.apple.developer.contacts.notes` | Unknown — not in the capability table at all | **Attempt it; the failure is loud** (`CNError.unauthorizedKeys`), so try and drop the key on throw |

---

# 5. IMPOSSIBLE — KILL THESE IDEAS NOW

| Idea | Why it dies | Best available proxy |
|---|---|---|
| **Read another app's notifications** | `UNUserNotificationCenter.current()` is per-app by construction ("Returns **your app's** notification center"). No entitlement exists at any tier. iOS has no `NotificationListenerService` analogue | **ANCS via a companion BLE device** (§6.19) — the iPhone is the ANCS *server*; a $5 ESP32 subscribes and logs every notification |
| **Read message content (iMessage/SMS)** | `MSConversation` — the richest object third-party code ever sees — exposes only `selectedMessage` (one **your** extension created), `localParticipantIdentifier`, and `remoteParticipantIdentifiers` which are **opaque UUIDs not resolvable to phone numbers, emails, or contacts** | Shortcuts `Message` trigger gives sender + body **for messages you pre-filter** — good enough for bank-alert parsing |
| **Read email** | **MailKit is macOS 12.0 only. It does not exist on iOS in any form.** `MFMailComposeViewController` is send-only and returns a result code | Shortcuts `Email` trigger: sender / subject / account / recipient |
| **Read Safari browsing history** | Safari Web Extensions run on iOS but the `history` permission is **accepted in manifest.json and completely inert** | A self-installed Safari Web Extension using the `tabs` API observes navigation **live, forward-only** |
| **Poll the clipboard** | Not a permission problem — a background-execution problem. iOS grants no arbitrary background execution; `UIPasteboard.changedNotification` fires only for your own app in the foreground | `UIPasteboard.detectPatterns(for:)` classifies contents **without reading them and without the paste banner** — but only when you're running |
| **Screen on/off time, device lock state** | Apple DTS, repeatedly: "there's no supported way to track the device lock state." Every proxy is broken in a specific way — `protectedData` needs a passcode and lags 10-40 s; `UIScene.SystemProtectionManager` is per-app Face ID gating; Darwin `com.apple.springboard.lockstate` is undocumented **and iOS will not resume a suspended app to deliver a Darwin notification** (Quinn, DTS thread 769398) | Charging + Low Power Mode + absence of lifecycle events, sustained → sleep window |
| **Screenshots taken in other apps** | `userDidTakeScreenshotNotification` fires **only while your app is on screen.** No cross-app log, no wake | `PHAssetMediaSubtype.photoScreenshot` retroactively — the full history, from the photo library |
| **Ring/silent switch position** | No public API, ever. The silent-sound-timing hack (`AudioServicesPlaySystemSound` completion latency) is unverified post-iOS-17 and burns an audio session | Focus status ($99), or the Shortcuts Focus trigger (free) |
| **Ambient light in lux** | The only true lux is `SRAmbientLightSample.lux` — SensorKit, approval-gated | HK `timeInDaylight`; `ARLightEstimate.ambientIntensity` (foreground); `UIScreen.brightness` |
| **Ambient air temperature** | iPhone thermistors are not exposed. Only ambient temps are HK `waterTemperature` and `CMAmbientPressureData.temperature` — **both Watch Ultra, both only while submerged** | Open-Meteo outdoor temperature |
| **Battery health / cycle count / charge wattage** | No public API. `batteryState` has 4 cases and cannot distinguish wired/MagSafe/Qi. `batteryLevel` quantized to 5% since iOS 17 | none |
| **Numeric device temperature** | `ProcessInfo.thermalState` gives 4 buckets. That is the entire public thermal surface | `activeProcessorCount` dropping = throttling |
| **Wi-Fi network scan (list of visible APs)** | No public API on **any** iOS version, free or paid. `NEHotspotHelper` is the only surface that ever exposed a scan list, and it's unobtainable | Bonjour device-set hashing |
| **Carrier name / MCC / MNC** | `CTCarrier` deprecated iOS 16, returns `"--"` and `65535` from the iOS 16.4 SDK. Apple DTS asked for an alternative: "No. That's what *Deprecated with no replacement* means." | `serviceCurrentRadioAccessTechnology` (still works) |
| **AirPods battery level, in-ear detection** | No public API for either. CoreMotion exposes **connection** state only (`DidConnect`/`DidDisconnect`) | `CMDeviceMotion.sensorLocation` flipping between `.headphoneLeft`/`.headphoneRight` when a bud is removed |
| **Another app's VPN state** | `NEVPNManager`/`NETunnelProviderManager` surface only configurations **your** app created — at every tier | `NWPath.unsatisfiedReason == .vpnInactive` + `utun*` interface **and** a matching `CFNetworkCopySystemProxySettings()['__SCOPED__']` entry (both required — `utun` alone false-positives on iCloud Private Relay and Continuity) |
| **Whole-device data usage across reboots** | Apple DTS: no supported solution. `getifaddrs` resets on reboot | MetricKit (own app, daily) + `getifaddrs` (since boot, all interfaces) |
| **Per-app data usage for other apps** | Apple DTS: "iOS isolates your app from other apps, so you're unlikely to get an API that returns per-app statistics for all apps" | none |
| **Whole system CPU load / running-app list** | `activeProcessorCount` is the only public hint. `host_processor_info`/`sysctl KERN_PROC` link but are undocumented and sandbox-restricted | none |
| **Photos People / Faces album** | **Not in PhotoKit.** `.albumSyncedFaces`/`.smartFolderFaces` are legacy iPhoto-sync artifacts, not the modern People album | Run **Vision** (`VNDetectFaceRectanglesRequest`, `VNGenerateFaceprintRequest`) over your own PHAssets and cluster yourself — on-device, no entitlement, just compute |
| **iOS "Significant Locations" system history** | No read API at any deprecation level. I enumerated the complete CoreLocation symbol index. `startMonitoringSignificantLocationChanges()` monitors *forward*; it does not expose the stored list | none — your log starts the day you install |
| **Detect whether the user denied a HealthKit read** | Apple, verbatim: "your app doesn't know whether someone granted or denied permission to read data… attempts to read return only samples that your app successfully saved." Intentional, no API will change it | `HKCharacteristicType` getters **throw** `errorAuthorizationDenied` — the only detectable denial, usable as a whole-sheet canary |
| **Sleep Score (iOS 26)** | Not in HealthKit. Grepping the 26.5 SDK for "Score" yields only workout-effort and the two scored assessments. Health-app-only | Reimplement from `sleepAnalysis` duration, bedtime consistency, interruptions |
| **Apple's derived interpretations** (AFib History %, Cardio Fitness notification logic, Walking Steadiness thresholds, Vitals outlier detection, wrist-temp deviation-from-baseline) | Health-app-only. HealthKit exposes the raw inputs, never Apple's interpretation | Compute your own from the raw samples |
| **`CMOdometerData` / `CMHighFrequencyHeartRateData`** | Announced on Apple's Core Motion updates page (June 2023) with full property sets and **no public API that returns them.** Verified by six-way exhaustion: framework symbol index, 532 crawled doc JSONs, references graph, xamarin-macios bindings, WWDC23 transcript, `HKWorkoutSession` header | none |
| **`TrollStore` permanent signing** | "16.7.x (excluding 16.7 RC) and 17.0.1+ will **NEVER** be supported." An iPhone on iOS 26.x cannot use it | none |
| **`EKEvent.travelTime`** | Does not exist. Zero hits for `/travel/i` across the entire EventKit index | none |
| ⚠ **App.InFocus from a Windows iTunes backup** | **UNSUBSTANTIATED, NOT KILLED.** ASTER's README claims the folder can be "extracted from an iPhone backup" — but grepping every `.py` in the repo for `backup\|MobileSync\|Manifest.db\|itunes` returns **zero hits**; only the macOS `~/Library/Biome` path is implemented. No prior art demonstrates it | **Cheap to test — a backup already exists on the Windows box. Probe Test #18.** Payoff is enormous |

---

# 6. THE NON-OBVIOUS TWENTY

Ranked by value × obscurity.

**1. `HKWorkoutRoute` gives you full-fidelity GPS traces with NO CoreLocation permission.**
`HKSeriesType.workoutRoute()` + `HKWorkoutRouteQuery` delivers `[CLLocation]` at ~1 Hz — latitude, longitude, altitude, speed, course, horizontal/vertical accuracy, timestamp — for **every outdoor workout ever recorded**, going back to the user's first Health-syncing device. It needs the base `com.apple.developer.healthkit` entitlement and the ordinary Health sheet's workoutRoute toggle. **No `NSLocationWhenInUseUsageDescription`, no CoreLocation authorization, no location-permission machinery engages at all** — the coordinates come out of HealthKit. This is simultaneously the most privacy-dense stream in HealthKit and the cheapest to obtain. Keep calling the query until `done == true`.

**2. The backfill asymmetry *is* the architecture, and it almost exactly cancels the 7-day signing gap.**
The motion coprocessor accumulates step/floor/distance and motion-activity classification continuously **whether or not your app has ever run**. `CMPedometer.queryPedometerData(from:to:)` and `CMMotionActivityManager.queryActivityStarting(from:to:to:)` recover the full prior **7 days**. `CMSensorRecorder` recovers **3 days** of 50 Hz accelerometer captured while suspended *or terminated*. HealthKit and PhotoKit hold **years**. Now notice: a free Personal Team profile expires in **7 days**. A logger that launches once every couple of days, and is re-signed weekly, loses essentially nothing of the historical record and burns zero background battery. Almost every tutorial gets this backwards and reaches for background modes first. **Design the harvest-on-launch path before the background path.**

**3. iOS 26's Shortcuts `Screen Time > Get App & Website Data` action routes around the Family Controls entitlement entirely.**
New in iOS 26 on iOS/iPadOS/macOS. Per-app and per-website usage, with **whatever Screen Time itself retains (typically ~4 weeks) of retroactive history** — the only surface in the Shortcuts domain with real backfill. `com.apple.developer.family-controls` is ADP-only and marked development-only; this action is free and needs no entitlement at all. Chain it to a background `AppIntent` and you have per-app screen time on a free Apple ID with history that threshold-counting can never produce.

**4. `HKHeartbeatSeriesSample` gives you raw beat-to-beat R-R intervals.**
`HKSeriesType.heartbeatSeries()` + `HKHeartbeatSeriesQuery` yields individual heartbeat timestamps at **sub-millisecond resolution** with a `precededByGap` flag. HealthKit publishes only SDNN as a quantity type; from the beat series you can compute RMSSD, pNN50, LF/HF, sample entropy — the entire HRV literature. Apple Watch only, base entitlement only, written alongside `heartRateVariabilitySDNN` during Breathe/Mindfulness and background HRV reads. **It is not present in usable form in the Health app XML export.** Most developers never touch it.

**5. `CMSensorRecorder` is the only entitlement-free way to get raw sensor data from a period when your app wasn't running.**
50 Hz accelerometer, recorded even if the app is suspended **or terminated**, retained 3 days, no entitlement, works on a free Apple ID. Undocumented gotchas that make people give up: (a) up to **3 minutes** of delivery lag before new samples appear; (b) `accelerometerData(from:to:)` rejects spans longer than **12 hours** — a 3-day pull needs six-plus paged queries; (c) it records nothing until Motion & Fitness is granted, and **the only way to trigger the prompt is to call `recordAccelerometer(forDuration: 0.1)`** — there is no `requestAuthorization` method; (d) `isAccelerometerRecordingAvailable()` is reported false on pre-A10 devices, a gate Apple has never documented. ⚠ Contested — Probe Test #4.

**6. `SetFocusFilterIntent` is a PUSH channel and almost nobody uses it that way.**
Every discussion frames Focus Filters as "let the user filter my app's content per Focus." Mechanically, **the system calls your intent with your `@Parameter` values on every Focus transition** — no automation, no Shortcuts, no user tap, no banner. It is the only surface in this entire domain where the OS notifies your app of a system state change directly. It also solves both problems the Focus *automation* trigger has: no "any Focus" option (you'd need 2N automations for N Focuses) and no way to know *which* Focus turned off. iOS 16+, free, no entitlement.

**7. Shortcuts `App` trigger (Is Opened / Is Closed) → background App Intent = self-built Screen Time.**
Native per-app usage needs Family Controls, which the free tier cannot sign. But the `App` automation trigger accepts multiple apps, fires on both open and close, and can Run Immediately. Open writes a timestamp; Close reads it, diffs, appends. This produces something the Screen Time API never does: **exact session boundaries rather than aggregated buckets.** Costs: no API creates automations (you hand-build two per app in the Shortcuts UI), and "Is Closed" is the less reliable half — backgrounding vs swiping away vs Jetsam do not all fire it, so sessions must be closed heuristically.

**8. `UIDocumentPickerViewController(forOpeningContentTypes: [.folder])` + a security-scoped bookmark is the only zero-permission, zero-entitlement, *persistent* arbitrary-file read on iOS.**
No Info.plist key. No prompt. No authorization status. The user's act of picking **is** the grant, and `url.bookmarkData(options: .minimalBookmark)` survives app relaunch and device reboot. Pick a folder once and you hold a durable window into a whole directory tree — perfect for ingesting exports, CSVs, backups, or note vaults. The universal first-time bug: you must call `startAccessingSecurityScopedResource()` before every access or reads fail with permission errors despite holding a valid URL, and you must balance it with `stopAccessing…` because concurrently-open scopes are hard-capped. Handle `bookmarkDataIsStale` by re-resolving and re-saving.

**9. `AVAudioSession.currentRoute.outputs[].portName` is the real answer to "what Bluetooth devices am I connected to."**
Zero permission, zero prompt, zero entitlement. Returns the literal user-visible names — "Zach's AirPods Pro", "Honda HFT", "Kitchen HomePod" — with `portType` distinguishing `.bluetoothA2DP` / `.bluetoothHFP` / `.carAudio` / `.airPlay`. **CoreBluetooth cannot see any of these**: cars, AirPods and most speakers are classic Bluetooth BR/EDR, and CoreBluetooth is BLE-only. Most developers reach for CoreBluetooth here and get nothing. Observe `routeChangeNotification` under the `audio` background mode for a continuous device-attachment log; `.carAudio` is a near-perfect driving detector.

**10. HealthKit `environmentalAudioExposure` is calibrated absolute dBASPL — your own meter is not.**
`AVAudioRecorder.averagePower(forChannel:)` returns **dBFS**, range −160 to 0, referenced to the ADC's digital full scale, with no defined relationship to acoustic dB SPL and no API for the per-device-model offset. Meanwhile Apple already runs a calibrated A-weighted dBASPL pipeline on the Watch and writes it into HealthKit — with **years of retroactive history**, no mic permission, and no battery cost. For ambient-dB quantified self this beats rolling your own.

**11. HealthKit `timeInDaylight` is a free lux-derived circadian signal.**
Everyone chasing ambient light goes to SensorKit (approval-gated) or ARKit (foreground-only, camera indicator). Meanwhile the Apple Watch has been sampling its ambient light sensor continuously since iOS 17 and writing a daylight-exposure aggregate into HealthKit, retrievable with a plain `HKStatisticsCollectionQuery` — full retroactive history sitting in the store on first launch. Requires Watch SE2 / Series 6+.

**12. Open-Meteo's archive lets you retroactively enrich your *entire existing history*. WeatherKit cannot.**
`archive-api.open-meteo.com/v1/archive` serves hourly reanalysis from **1940 to present** for arbitrary coordinates, free and keyless. Join it against HealthKit's full retroactive store and every `HKWorkoutRoute` and you have years of biometrics against actual weather, pressure, daylight duration and solar radiation at your exact location on each day. The air-quality endpoint adds PM2.5, PM10, O₃, NO₂, SO₂, CO, AOD, dust and birch/grass/ragweed pollen — an entire environmental-exposure axis Apple exposes nowhere.

**13. The `desiredAccuracy = 999` shield trick (Arc Timeline, production, DTS-sourced).**
LocoKit2 runs **two** `CLLocationManager`s. The real one keeps `distanceFilter = 3` for high-resolution recording; a second permanent one exists only as a keep-alive, configured `desiredAccuracy = 999` (the source comment says *"just under the magic 1000"*), `distanceFilter = kCLDistanceFilterNone`, `showsBackgroundLocationIndicator = false`. The comment's hypothesis: a sole `df=3` session is what cues Apple's background suspensions, and the compliant second session "shields" it. Paired with this: **`CLServiceSession(authorization: .always)` does NOT force the blue indicator, while `CLBackgroundActivitySession()` does.** For an app you use all day, that one-line substitution removes a permanent status-bar indicator.

**14. The 71 `HKMetadataKey` constants are a free second data layer riding samples you already read.**
`WasUserEntered` separates sensor truth from typed-in guesses. `WeatherCondition` / `WeatherTemperature` / `WeatherHumidity` give free weather history on every outdoor workout. `BarometricPressure` gives ambient pressure. `HeartRateMotionContext` (notSet/sedentary/active) is **the only reliable way to identify resting-context beats**. `QuantityClampedToUpperBound`/`LowerBound` flags values that hit a sensor ceiling and are therefore **not real readings** — critical for not treating clipped data as signal. `DeviceSerialNumber` + UDI identify the exact hardware.

**15. Bonjour device-set hashing is the free replacement for BSSID place fingerprinting.**
You cannot read the SSID on a free account. But `NWBrowser` (iOS 26: `NetworkBrowser`) over a declared list of service types returns the actual set of devices on the LAN — Apple TVs, HomePods, printers, NAS, other Macs. Hash that set and you have a per-place identifier with **far more entropy than the gateway IP**, for one Info.plist array and one runtime prompt. Harden against a device being powered off by cross-checking `NWPath.gateways` and `supportsIPv6`. Declare service types up front: `_airplay._tcp`, `_raop._tcp`, `_companion-link._tcp`, `_homekit._tcp`, `_ipp._tcp`, `_googlecast._tcp`, `_http._tcp`, `_ssh._tcp`.

**16. `NWInterface.name` is a free, entitlement-less side channel and almost nobody uses it.**
`NWPath.availableInterfaces` hands you raw BSD names with no permission. From names alone: **VPN/tunnel active** (`utun*`, `ipsec*`, `ppp*`), **AirDrop/AirPlay/Handoff in progress** (`awdl0` up), **this device is SHARING a hotspot** (`bridge100` + `ap1`), **which SIM carries data** (`pdp_ip0` vs `pdp_ip1`). And separately, from Apple's own documented semantics for `isExpensive` ("Cellular or a Personal Hotspot"): **`usesInterfaceType(.wifi) && isExpensive == true` means you are tethered to *someone else's* hotspot** — a documented inference, not a hack, and it cleanly distinguishes being tethered from sharing. ⚠ Apple DTS notes BSD names are not formally API; treat as heuristic.

**17. `HKQuantitySeriesSampleQuery` expands a summary sample into its underlying high-frequency stream.**
Run only `HKSampleQuery` and you get pre-aggregated values. Run `HKQuantitySeriesSampleQuery` over the *same* samples and you get per-second `cyclingPower`, `runningPower`, `underwaterDepth` and more. Widely missed. iOS 12+, base entitlement.

**18. Geocode once, store `MKMapItem.Identifier`, re-resolve forever.**
`MKMapItem.Identifier` is archivable via `init(identifierString:)` and `MKMapItemRequest(mapItemIdentifier:)` resolves it back to a full named `MKMapItem`. Under an **undocumented ~50-requests-per-60-seconds** ceiling (Apple publishes only qualitative guidance: "not more than one geocoding request per minute"; the 50/60 figure is a developer-captured server throttle string, and `MKReverseGeocodingRequest` has **no** documented limit at all — only a hedged DTS forum reply), this is the difference between a place log that scales to years and one that throttles out in month two. The naive design reverse-geocodes every visit; the correct one geocodes each **new cluster centroid** once.

**19. ANCS via a companion BLE device is the only real path to cross-app notifications, and it's legitimate.**
The Apple Notification Center Service inverts the usual roles: the iPhone is the BLE **server**, a paired accessory is the **client**. Apple's own spec: ANCS gives "Bluetooth accessories… a simple and convenient way to access many kinds of notifications that are generated on iOS devices" — app identifier, title, message, date, category, for **every app**. An iOS app acting as a CoreBluetooth central cannot consume its own device's ANCS. But a **~$5 ESP32 or nRF52 paired to the iPhone can subscribe to ANCS and log every notification**, then hand the log back over BLE, Wi-Fi, or a file. For a self-installed personal rig where the owner is the subject, this is a clean, documented, no-entitlement route to the one stream iOS otherwise makes impossible.

**20. `HKActivitySummary` carries the ring GOALS — and cannot be observed in the background.**
`activeEnergyBurnedGoal`, `exerciseTimeGoal` (iOS 16), `standHoursGoal` (iOS 16), `appleMoveTimeGoal`, `activityMoveMode`, `isPaused` (iOS 18). **These exist nowhere else in HealthKit.** But `HKActivitySummaryType` is `HKObjectType` and **not** `HKSampleType`, so `HKObserverQuery` and `enableBackgroundDelivery` do not apply — `HKActivitySummaryQuery.updateHandler` only fires while your app is running. And the query needs an `NSPredicate` on `HKPredicateKeyPathDateComponents` built from an **explicit `NSCalendar` with the correct era and timezone**, or you silently get zero results with no error.

**Runners-up, all genuinely valuable:** `getifaddrs` gives you free since-boot backfill *and* a reboot detector from the same sampler · MetricKit is the only Apple-sanctioned byte counter and is free · `URLSessionTaskTransactionMetrics` is a free network-quality lab (11 timestamps + 6 byte counters per request) · automatic dark mode flips at civil twilight = free daylight-hours series with no location permission · `CMAltitudeData.pressure` is absolute kPa comparable across sessions while `relativeAltitude` is zeroed per session · `CMHeadphoneActivityManager` (iOS 18) classifies **the person** even when the phone is in another room · `activeProcessorCount` dropping below `processorCount` is a free thermal-throttle detector · `HKAnchoredObjectQuery` is the **only** way to observe deletions (`HKDeletedObject`) — a sync built on `HKSampleQuery` accumulates ghost records forever · `HKCharacteristicType` getters throwing is your only read-denial canary · `EKEvent.birthdayContactIdentifier` is a free cross-store join key to `CNContact` · `CNChangeHistoryFetchRequest.excludedTransactionAuthors` stops your app feeding on its own writes · `SpeechDetector` (iOS 26) measures how much you spoke **without transcribing a single word**.

---

# 7. BACKGROUND EXECUTION MODEL

## 7.1 The universal rule

**Notifications are event-lossy when suspended. Properties are pollable on any wake.**

Apple DTS's Darwin-notification answer generalizes: a suspended app receives nothing, and if terminated while suspended it never receives the missed events at all. But the underlying *properties* are process-local reads with no gate.

- **Event-lossy** (never build on edge detection alone): every `*DidChangeNotification` — battery level/state, thermal, power state, brightness, capture, screenshot, orientation, proximity, all 21 accessibility notifications, timezone, locale, `EKEventStoreChanged`, `PHPhotoLibraryChangeObserver`.
- **Pollable on wake**: `batteryLevel`, `thermalState`, `isLowPowerModeEnabled`, `os_proc_available_memory()`, disk capacities, `NWPath.currentPath`, `TimeZone.current`, `getifaddrs`, every `UIAccessibility.is*Enabled`, `CMPedometer` 7-day query, `CMMotionActivity` 7-day query, `CMSensorRecorder` 3-day pull, HealthKit anchored queries, PhotoKit persistent change token.
- **Hard foreground-only even when polled**: `UIScreen.brightness` (screen is off), `UITraitCollection` (needs a live trait environment), `UIDevice.orientation`, `proximityState`, anything screenshot/capture.

**Design consequence: poll a full snapshot on every wake and reconstruct edges offline.**

## 7.2 What relaunches a terminated app

| Source | Relaunches? | Re-call required on relaunch? | Survives reboot? | Survives force-quit? |
|---|---|---|---|---|
| `CLVisit` (`startMonitoringVisits`) | **YES** (Always) | **NO** — "You don't need to call this method again" | ⚠ Apple silent | ⚠ contested |
| Significant location change | **YES** (Always) | **YES — you MUST call it again or the service dies** | ⚠ Apple silent | ⚠ contested |
| `CLMonitor` / region monitoring | **YES** (Always) | **YES** — recreate with the same identifier | **Only after first unlock post-reboot** | ⚠ contested |
| HealthKit `HKObserverQuery` + background delivery | **YES** | Create in `didFinishLaunchingWithOptions` | **YES — registration is system-stored** | **NO — confirmed by Apple DTS, forum 803365** |
| CoreBluetooth state restoration | **YES** (matched service UUIDs only) | Implement `willRestoreState:` | yes | no |
| `CMFallDetectionManager` | **YES** | — | yes | — |
| **Shortcuts personal automations** | **YES — runs with no app involvement at all** | no | **yes** | **YES** ← the only one |
| `BGTaskScheduler` | wakes, opportunistic | resubmit each run | yes | **NO** |
| Silent push (`aps-environment`) | YES | — | yes | no | *($99)* |
| `startUpdatingLocation` | **NO — "delivery of new location events stops altogether"** | — | — | — |
| `CMMotionManager`, `CMHeadphoneMotionManager`, `AVAudioRecorder` metering | **NO** | — | — | — |

**Force-quit, honestly:** HealthKit background delivery is **confirmed dead** until the user manually relaunches (Apple DTS: "iOS… sets a flag that prevents the app from being launched in the background. That flag gets cleared when the user next launches the app manually… there's no documented way for your app to override the user's choice"). CoreLocation is **contested** — Apple's current docs treat "terminated" uniformly, but long-standing community reports hold that a *user* force-quit suppresses relaunch until reboot. The forum thread asking verbatim ("Do user-terminated apps relaunch automatically for location changes?", 701377) has **no Apple reply**. Design as if dead; detect via time holes.

**Reboot, honestly:** Apple's own docs contradict themselves. The condition-monitoring article says "The system monitors your conditions until you explicitly ask it to stop **or until the device reboots**." The `monitoredRegions` page says registrations "persist between launches." The `CLMonitor` article says monitoring resumes after first unlock. These cannot all be true. **Only safe design: re-register everything unconditionally on every launch.**

## 7.3 Background modes — the complete iOS list

```
audio · location · voip · external-accessory · bluetooth-central · bluetooth-peripheral
fetch · remote-notification · processing · nearby-interaction · push-to-talk
```
**There is no `motion`, no `fitness`, no `sensors`.** The widely-repeated advice to "enable the Motion & Fitness background mode in Xcode Capabilities" (forum thread 715100) is **factually wrong — that toggle does not exist.** To keep `CMMotionManager` or `CMHeadphoneMotionManager` streaming while backgrounded you must already be alive for another reason.

`UIBackgroundModes` is an **Info.plist array, not a signed entitlement** — but "Background modes" *is* a capability in Apple's table, and it is **checked in the free column**. This single row is what makes the whole project viable: every "POLL" row in §1 silently promotes to "YES" the moment you hold a continuous background mode.

## 7.4 The recommended layered strategy

```
LAYER 5 — EXTERNAL (survives everything, incl. force-quit)
  Shortcuts personal automations → background AppIntent
  · charger connect/disconnect · Wi-Fi join · Bluetooth connect · NFC tap
  · app open/close · arrive/leave · alarm · sleep · workout · Focus change
  · daily Time-of-Day reconciliation sweep  ← THE HEARTBEAT

LAYER 4 — RESURRECTION (relaunches a terminated app)
  CLVisit + significant-change under Always authorization
  CLMonitor: 20 rotating conditions, re-added nearest-first on every SLC event
  HKObserverQuery + enableBackgroundDelivery, created in didFinishLaunchingWithOptions
  ALL re-registered unconditionally on every launch

LAYER 3 — RESIDENCY (keeps a running app running)
  UIBackgroundModes = [location]
  CLLocationManager.allowsBackgroundLocationUpdates = true
  pausesLocationUpdatesAutomatically = FALSE          ← non-negotiable
  desiredAccuracy = kCLLocationAccuracyThreeKilometers when backgrounded
  (or CLBackgroundActivitySession under WhenInUse; CLServiceSession(.always)
   if you want residency without the blue indicator)
  → promotes every POLL row to continuous
  → restart motion updates on every foreground→background transition (see below)

LAYER 2 — OPPORTUNISTIC
  BGProcessingTask (requiresExternalPower) for heavy sync/compaction
  BGAppRefreshTask for light snapshots

LAYER 1 — RETROACTIVE HEALING (runs on EVERY launch, before anything else)
  HealthKit anchored queries from saved HKQueryAnchor  (years)
  PhotoKit fetchPersistentChanges(since: token)         (full library)
  CMPedometer.queryPedometerData                        (7 days)
  CMMotionActivityManager.queryActivityStarting         (7 days)
  CMSensorRecorder.accelerometerData, paged ≤12h        (3 days)
  getifaddrs diff                                       (since boot)
  MetricKit pastPayloads                                (~7 days)
  Shortcuts Screen Time action                          (~4 weeks)
  EventKit / Contacts snapshot+diff                     (complete)
```

**Five mandatory disciplines:**

1. **Create every `HKObserverQuery` inside `application(_:didFinishLaunchingWithOptions:)`.** HealthKit fires update handlers for pending deliveries *the instant* your app launches; a query registered a few hundred ms later misses that delivery. And you **must** call `HKObserverQueryCompletionHandler` — **three failures and HealthKit permanently stops delivering for that type.**

2. **Restart motion updates on every foreground→background transition.** Forum 88480 (iOS 11, iPhone 7 Plus, with `audio` AND `location` modes set) reports `CMMotionManager` updates simply stopping on backgrounding; the confirmed workaround is `stopDeviceMotionUpdates()` then `startDeviceMotionUpdates(...)` again from `applicationDidEnterBackground`. Forum 126045 (iOS 13.1) reports the same with zero replies. Apple has never documented it either way.

3. **`pausesLocationUpdatesAutomatically` defaults to TRUE and under WhenInUse a pause is PERMANENT.** Verbatim: "For apps that have in-use authorization, a pause to location updates ends access to location changes until the app launches again." The out-of-the-box configuration silently kills a long-running log the first time you sit still, with no error and no delegate callback. Apple's own prescribed workaround is counterintuitive: set it **false** and drop `desiredAccuracy` instead.

4. **Rotate the 20 conditions.** The cap is per-app-*simultaneous*, not per-app-total. Keep the full place list in your own store; on every significant-change event (you're already relaunched, so it's free) re-add the 20 nearest and remove the rest. `CLMonitor.Event.conditionLimitExceeded` (iOS 18+) tells you when you overflowed. Note the field crash: recreating a `CLMonitor` with the same name too soon after discarding the previous instance throws *"Monitor named X is already in use"* — which is **exactly the relaunch path Apple instructs you to take.**

5. **Persist a collection-viability channel alongside every sample.** `UIApplication.backgroundRefreshStatus`, whether a background mode is held, the launch trigger, and the timestamp of the last successful wake. In a domain where device/network/location have **zero backfill**, a gap caused by force-quit, by an expired profile, or by the user toggling off Background App Refresh is otherwise **indistinguishable from a gap caused by the user genuinely doing nothing.** Silently misattributed gaps are the dominant failure mode.

## 7.5 Copy two schemas verbatim from prior art

**Home Assistant's `LocationUpdateTrigger` — a 20-case wake taxonomy with measured timeout budgets:**
```
RegionEnter RegionExit GPSRegionEnter GPSRegionExit BeaconRegionEnter BeaconRegionExit
Manual SignificantLocationUpdate BackgroundFetch PushNotification URLScheme XCallbackURL
Siri Visit AppShortcut Launch Periodic Signaled Unknown watchContext
```
Each carries a field-earned `oneShotTimeout`: **20 s** for region/visit events, **10 s** for SLC / background-fetch / push / watch, **30 s** for user-initiated. Those are the right starting budgets for a sync that must complete before suspension.

**LocoKit2's `DailyRecordingStats` — one row per local day:**
```
dayKey utcOffset secondsRecording secondsSleeping secondsWakeup secondsStandby
restartCount wakeupCount wakeupTimeoutCount chainStallCount appLaunchCount samplesRecorded
```
This is a *measured* answer to "did iOS actually keep my app alive today," broken down by state, with failure counters rather than a boolean. Arc ships it in production. Implement it on day one and the background question stops being a research question.

---

# 8. BUILD PIPELINE — WINDOWS ONLY

## 8.1 Repo layout

```
ios-telemetry/
  project.yml                          ← XcodeGen manifest, plain text, authored on Windows
  Probe/
    ProbeApp.swift  AppDelegate.swift  Info.plist  Probe.entitlements
    Collectors/  Store/  Model/
  ProbeWidget/                         ← ONE extension max, or zero (App-ID budget)
    Info.plist  ProbeWidget.entitlements
  .github/workflows/build.yml
```

**Public repo** for free unlimited macOS CI. Discipline: **code only** — never health data, never the Apple ID, never a device pairing file.

## 8.2 `project.yml`

```yaml
name: Probe
options:
  bundleIdPrefix: com.zacharyahmed
  deploymentTarget: { iOS: "26.0" }
  createIntermediateGroups: true
settings:
  base:
    DEVELOPMENT_TEAM: ""
    SWIFT_VERSION: "6.0"
    TARGETED_DEVICE_FAMILY: "1,2"
targets:
  Probe:
    type: application
    platform: iOS
    sources: [Probe]
    info:
      path: Probe/Info.plist
      properties:
        NSHealthShareUsageDescription: "Reads your own health data."
        NSHealthUpdateUsageDescription: "Writes your own health data."
        NSMotionUsageDescription: "Reads motion and step data."
        NSLocationWhenInUseUsageDescription: "Logs where you go."
        NSLocationAlwaysAndWhenInUseUsageDescription: "Logs where you go, in the background."
        NSLocationAlwaysUsageDescription: "Logs where you go, in the background."
        NSMicrophoneUsageDescription: "Classifies ambient sound on-device."
        NSCalendarsFullAccessUsageDescription: "Reads your calendar."
        NSRemindersFullAccessUsageDescription: "Reads your reminders."
        NSContactsUsageDescription: "Reads your contacts."
        NSPhotoLibraryUsageDescription: "Reads photo metadata."
        NSAppleMusicUsageDescription: "Reads your music library."
        NSBluetoothAlwaysUsageDescription: "Detects nearby devices."
        NSLocalNetworkUsageDescription: "Fingerprints the network you are on."
        NSBonjourServices: [_airplay._tcp, _raop._tcp, _companion-link._tcp,
                            _homekit._tcp, _ipp._tcp, _googlecast._tcp, _http._tcp]
        UIBackgroundModes: [location, processing, fetch, audio, bluetooth-central]
        BGTaskSchedulerPermittedIdentifiers:
          - com.zacharyahmed.Probe.refresh
          - com.zacharyahmed.Probe.process
        UIApplicationSceneManifest:                # iOS 27 REQUIRES scene lifecycle
          UIApplicationSupportsMultipleScenes: false
    entitlements:
      path: Probe/Probe.entitlements
      properties:
        com.apple.developer.healthkit: true
        com.apple.developer.healthkit.background-delivery: true
        com.apple.security.application-groups: [group.com.zacharyahmed.Probe]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.zacharyahmed.Probe
        REGISTER_APP_GROUPS: YES                   # Apple DTS fix for Xcode 16.4+
schemes:
  Probe:
    build: { targets: { Probe: all } }
```

**Also delete `healthkit` from `UIRequiredDeviceCapabilities`** if XcodeGen or Xcode adds it — it blocks install on non-HealthKit devices.
**Use iOS-style App Group IDs (`group.com.you.app`), never `$(TeamIdentifierPrefix)group...`** — Apple DTS explicitly recommends the iOS style, and the mixed form is a known cause of "Provisioning profile doesn't support the App Groups capability."

## 8.3 GitHub Actions workflow

```yaml
name: build-unsigned-ipa
on: [push, workflow_dispatch]
jobs:
  build:
    runs-on: macos-26            # macOS 26.4, Xcode 26.5 DEFAULT, iphoneos26.5 SDK
    steps:                       # NOT macos-14 (deprecated); on macos-15 the
      - uses: actions/checkout@v4   # default is still Xcode 16.4 / iOS 18.5 SDK
      - run: brew install xcodegen
      - run: xcodegen generate
      - name: Build unsigned
        run: |
          xcodebuild archive \
            -project Probe.xcodeproj -scheme Probe -configuration Release \
            -destination 'generic/platform=iOS' -archivePath unsigned.xcarchive \
            CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
      - name: Package .ipa
        run: |
          mkdir -p Payload
          cp -R unsigned.xcarchive/Products/Applications/Probe.app Payload/
          zip -r Probe.ipa Payload
      - uses: actions/upload-artifact@v4
        with: { name: Probe-unsigned-ipa, path: Probe.ipa }
```

**All three signing flags are needed together.** `REQUIRED=NO` alone still lets Xcode try to resolve an identity; the empty `CODE_SIGN_IDENTITY` is what stops provisioning-profile lookup. **Do not pass `-allowProvisioningUpdates`** (no Apple ID on the runner).

**`xcodebuild -exportArchive` CANNOT be used** — it requires a signing identity and an `ExportOptions.plist` distribution method. Hand-zipping `Payload/` is the only Mac-free path. An `.ipa` is literally a zip with a top-level `Payload/` directory.

**Do not use `find build -name '*.app' | head -n 1`** — the line in almost every copy-paste workflow. With extensions it can grab a Watch app or a dependency's product. Hard-code `unsigned.xcarchive/Products/Applications/Probe.app`.

**If you add an extension:** set `ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES=NO` on the extension target (only the app should ship `Frameworks/libswift*.dylib`; duplicates produce invalid nested code). Skip `SwiftSupport/` — it's an App Store artifact.

**Side benefit of `CODE_SIGNING_ALLOWED=NO`:** no `_CodeSignature/` directories are emitted anywhere, including nested `.appex` bundles, so the Windows re-signer never has to strip stale nested signatures — a classic source of "invalid code signature" install failures.

## 8.4 Windows install

**Sideloadly** (v0.60.0, Windows 10/11).
**Hard requirement: install iTunes and iCloud from the WEB (apple.com), NOT the Microsoft Store.** The Store builds sandbox the folders anisette data is read from → "invalid anisette data" / connection failures. Same requirement for AltServer.

Flow: download the artifact → Sideloadly → drop the `.ipa` → Apple ID + password + 2FA code (**app-specific passwords only work with paid IDs when anisette is disabled**) → install over USB or Wi-Fi → on device, Settings → Privacy & Security → **Developer Mode** on (requires passcode + reboot; the toggle only appears after a dev-signed app is installed) → Settings → General → VPN & Device Management → Trust.

Sideloadly relevant features: remove individual or all app extensions before install, bundle-ID/name/icon rewriting, minimum-iOS rewriting, Wi-Fi sideloading, dylib injection.

## 8.5 Re-sign cadence — the 7-day treadmill

| Limit | Value |
|---|---|
| Provisioning profile validity | **7 days** |
| Signing identity validity | 1 year |
| Apps installed simultaneously | **3** (a sideloader app like SideStore burns one; Sideloadly does not) |
| App IDs per rolling 7 days | **10** — **each app extension consumes its own App ID** |
| Registered devices | 3 per platform |

**What actually breaks on expiry:** (1) the app refuses to launch — "Unable to Verify App"; (2) **background execution stops SILENTLY** — `BGTaskScheduler`, significant-location wakes, and HealthKit background delivery all work by the *system relaunching your app*, which fails against an expired profile with **no user-visible error**. You find out days later from a hole in the data. (3) **Data DOES survive** re-signing, provided you use the **same Apple ID** — same Team ID ⇒ same `application-identifier` prefix ⇒ install-over preserves the container. **Change Apple IDs and iOS treats it as a different app; you must delete first, losing everything.** Never rotate Apple IDs on a data-collecting app.

**Automation, honestly:** **Sideloadly has no documented command line.** Verified against both `sideloadly.io/faq.html` and the official `SideloadlyiOS/Sideloadly-Download` README — both silent on CLI, scripting, and automation. A Task Scheduler job driving `sideloadly.exe --args` is not a supported plan. What is: leave the **Sideloadly Daemon** running with credentials saved and auto-refresh on, and additionally install **AltStore Classic** with Background Refresh enabled. Two independent mechanisms race to beat the expiry — Sideloadly's fires when it *sees* the device; AltStore's is initiated *by the phone* against AltServer. Track AltStore Classic 2.3b1, which adds fully on-device sideloading via a user-supplied anisette server, removing the Windows box from the loop.

**Also:** a free Apple ID has a tiny certificate budget. Signing from a second machine or a second tool can revoke the existing certificate, instantly bricking every app signed by it and forcing a re-Trust. **Pick ONE Windows machine and ONE tool as the signer of record.**

## 8.6 Cost math

| | Public repo | Private repo |
|---|---|---|
| macOS runner cost | **$0, unlimited** (standard labels only — `macos-*-large`/`-xlarge` are always billed even on public repos) | 10× multiplier: 2,000 included min ÷ 10 = **200 macOS min/mo ≈ 20 ten-minute builds**, then $0.062/min |
| Per-build overage | — | 10 min × $0.062 = **$0.62** |
| 16 builds/mo beyond allowance | — | ≈ **$9.92/mo ≈ $119/yr** |

**A private repo with moderate CI costs more per year than the $99 Apple Developer Program — which would also eliminate the 7-day expiry, the 3-app limit, the 10-App-ID limit, and the entire entitlement question.** Use a public repo with strict data hygiene, or pay the $99.

**Order of operations to minimise wasted App IDs** (metered at 10 per rolling 7 days, unbuyable on a free ID): (1) push a 20-line HealthKit stub, sideload, confirm the auth sheet appears; (2) *only then* add App Groups + an extension; (3) *only then* write the real app. **CI iterations are free; device installs are scarce.**

---

# 9. PHASED BUILD ORDER

## Phase 0 — THE PROBE (days 1–5)

**Ships:** a ~600-line app that answers "what actually works on THIS phone" and writes a machine-readable report to Files.

**Do these two things first, before anything else:**
1. **Probe Test #1** — stub with only `com.apple.developer.healthkit`. Sideload. Does the Health authorization sheet appear? (Three outcomes: install fails `0xe8008016` ⇒ profile refused the entitlement, HealthKit is **dead on free**; installs but `requestAuthorization` fails/crashes ⇒ the signer **stripped** the entitlement, also dead; sheet appears ⇒ proceed.)
2. **Probe Test #2** — add `background-delivery`. Does `enableBackgroundDelivery(for:frequency:)` complete without `HKError.errorAuthorizationDenied`?

Those two booleans determine whether Phases 1–3 exist in their planned form. Everything below is downstream.

**Then, the capability self-report.** Copy OwnTracks' `_type=status` iOS object verbatim — it is this exact schema, already designed and shipping:
```
altimeterAuthorizationStatus  altimeterIsRelativeAltitudeAvailable  backgroundRefreshStatus
deviceIdentifierForVendor  deviceModel  deviceSystemName  deviceSystemVersion
deviceUserInterfaceIdiom  locale  localeUsesMetricSystem  locationManagerAuthorizationStatus
motionActivityManagerAuthorizationStatus  motionActivityManagerIsActivityAvailable
pedometerIsDistanceAvailable  pedometerIsFloorCountingAvailable  pedometerIsStepCountingAvailable
```
Extend it with: `HKHealthStore.isHealthDataAvailable()`, per-type `getRequestStatusForAuthorization`, the `HKCharacteristicType` read-denial canary, `CMSensorRecorder.isAccelerometerRecordingAvailable()`, `CMSensorRecorder.authorizationStatus()`, `SNClassifySoundRequest.knownClassifications.count`, `CLLocationManager.accuracyAuthorization`, `NWPath` snapshot, `CMAltimeter.isAbsoluteAltitudeAvailable()`, `WCSession.isPaired`/`isWatchAppInstalled`.

**Plus the two prior-art schemas:** `LocationUpdateTrigger` launch ledger (20 cases + measured timeouts) and `DailyRecordingStats`.

**De-risks:** everything. Phase 1 has no harvest if Test #1 fails.

## Phase 1 — THE HARVEST (weeks 2–3)

**Ships:** a local SQLite (GRDB) store containing years of your actual life, with **zero background dependency**. Even if every background mechanism fails, this phase alone is a working quantified-self dataset.

- HealthKit full history via `HKAnchoredObjectQuery(anchor: nil)`, paged with `limit` (an unbounded first sync of `heartRate` is hundreds of thousands of samples). Persist `HKQueryAnchor` per type. `HKStatisticsCollectionQuery` for daily rollups — **it applies Apple's cross-source deduplication that manual summing does not.**
- Every `HKWorkout` + `HKWorkoutRoute` GPS trace + per-workout statistics + the 71 metadata keys.
- `HKHeartbeatSeriesSample`, `HKElectrocardiogram`, `HKAudiogramSample`, `HKStateOfMind`, medications, activity summaries (with goals).
- PhotoKit full library metadata — **set `includeHiddenAssets: true` and `includeAllBurstAssets: true`** or your counts are silently wrong. Persist `PHPhotoLibrary.currentChangeToken` and `PHCloudIdentifier` (not `localIdentifier` — it changes on restore).
- EventKit events + attendees + reminders. Contacts + **take `CNContactStore.currentHistoryToken` immediately** (contacts change history is forward-only and irrecoverable if you don't start it).
- `CMPedometer` 7 days, `CMMotionActivityManager` 7 days (store the full 6-bit vector + confidence, never a collapsed label — a car at a red light is `automotive && stationary`, and all six can be false).
- `CMSensorRecorder` 3-day pull, paged in ≤12 h spans.
- Shortcuts `Get App & Website Data` → App Intent.
- Music library counters + `libraryAddedDate`.

**Schema disciplines to bake in now:** `source` + `sourceVersion` columns on every table; nullable `secondsFromGMT` (a decade-old log has schema archaeology); separate `classifiedX` and `confirmedX` columns so a machine guess never overwrites a human correction; **denormalise health rollups onto the timeline segment, not the day** — that's what turns "average heart rate in July" into "heart rate at the office vs the gym vs driving."

**De-risks:** proves the store, the schema, and the volume before you fight the OS for liveness.

## Phase 2 — THE RESIDENT (weeks 4–6)

**Ships:** continuous collection with instrumented reliability.

- Layer 4 resurrection (visits + SLC + 20 rotating conditions + HK observers), all re-registered on every launch.
- Layer 3 residency (`UIBackgroundModes: location`, `pauses=false`, 3 km accuracy when backgrounded; A/B the `CLServiceSession(.always)` + `showsBackgroundLocationIndicator=false` shield against the `CLBackgroundActivitySession` baseline).
- Full snapshot poll on every wake: battery, thermal, LPM, memory, disk, network path + `getifaddrs` + BSD interface names, timezone, accessibility flags, audio route.
- `CMAltimeter` pressure logging (log `pressure` in kPa, **not** `relativeAltitude` which is zeroed per session).
- `SNClassifySoundRequest` duty-cycled (10 s every 5 min, not continuous — mic + CoreML inference is expensive). If you ship a custom CoreML classifier, **pin `MLComputeUnits` to `.cpuOnly` for background** — iOS restricts GPU work from background processes.
- Shortcuts automations built and wired to background App Intents.
- `DailyRecordingStats` written every day. Heartbeat row on every background wake, with staleness alarming.

**De-risks:** you now know your real background survival rate, measured, before you build anything on top of it.

## Phase 3 — THE ENRICHER (week 7+)

**Ships:** meaning.

- Cluster visit centroids offline (pure arithmetic, works forever with no network). **Name each cluster ONCE** via `MKReverseGeocodingRequest`, persist `MKMapItem.Identifier`, never spend throttle budget on it again. Fall back to `MKLocalPointsOfInterestRequest` around the centroid to get the *business* rather than the street address.
- Open-Meteo archive join across **the entire historical dataset** — weather, pressure, daylight duration, solar radiation, PM2.5, pollen for every day you have data.
- Derived metrics: sleep windows from charger + LPM + lifecycle silence; HRV from the beat series (RMSSD, pNN50, LF/HF); dwell times from arrive/leave pairs; commute detection from `.carAudio` + `automotive`; place histograms (arrival times, leaving times, durations, occupancy).
- **Speak an existing wire format.** Emitting the OwnTracks or Overland payload gets you Dawarich (9,870★), Home Assistant, Compass, Wayfinder and half a dozen importers for free. A bespoke schema buys nothing a translation layer at the VM couldn't provide, and costs all of that.
- Sync as a **resumable projection**: the phone queues locally and deletes only on an explicit server ACK (Overland's contract is literally `{"result":"ok"}`). Stamp every payload with the *settings that produced it* (`desiredAccuracy`, `pauses`, `deferred`, `significant_change`) so a year later you can tell a data gap from a config change. Keep **both** timestamps — fix time and send time — so a queue flushing three hours late is distinguishable from three hours of real movement.

---

# 10. OPEN QUESTIONS FOR THE DEVICE PROBE

Each is stated as a **testable assertion**. Run these on the actual iPhone before designing around any of them.

### Blocking — run first

1. **`com.apple.developer.healthkit` signs on a free Personal Team via Sideloadly, and `HKHealthStore.requestAuthorization` presents the Health sheet.** *Fail mode A: install rejects with `0xe8008016`/"Entitlements are not valid" ⇒ profile refused. Fail mode B: installs, then reads return empty / crash ⇒ signer stripped it.*
2. **`com.apple.developer.healthkit.background-delivery` signs, and `enableBackgroundDelivery(for:frequency:)` completes without `HKError.errorAuthorizationDenied`.** *It is not a row in Apple's capability table and not configurable in the App ID portal UI — it exists only because Xcode writes it. Your pipeline never runs Xcode's capability UI.*
3. **`com.apple.security.application-groups` signs on a free Personal Team via this pipeline.** *Apple's table says yes; a retired 2018 Xamarin doc says no; AltSign proves the developerservices2 API accepts it. Xcode's Signing UI denylist and the API allowlist are different things.*

### Background survival

4. **A `UIBackgroundModes: location` + Always-authorized app remains resident for ≥24 h continuously**, and I can quantify the battery cost per hour.
5. **HealthKit background delivery survives a device reboot** (registration is system-stored) **and does NOT survive a user force-quit** (Apple DTS, forum 803365).
6. **CoreLocation visits/SLC/region relaunch does NOT survive a user force-quit.** *Contested; no Apple statement exists. Test by swipe-killing, then physically leaving and returning to a geofence.*
7. **`CLMonitor` conditions resume after reboot only after first unlock**, and recreating a monitor with the same name on relaunch does **not** throw "Monitor named X is already in use."
8. **`CMMotionManager` device-motion updates stop on backgrounding on iOS 26 even with a valid background mode, and `stop→start` from the background transition handler restores them.**
9. **`CLServiceSession(authorization: .always)` with `showsBackgroundLocationIndicator = false` sustains background location without the blue indicator**, and its survival rate is not worse than `CLBackgroundActivitySession`.

### API behaviour Apple has not documented

10. **`CMSensorRecorder.isAccelerometerRecordingAvailable()` returns true on this iPhone on iOS 26**, and `accelerometerData(from:to:)` returns non-nil data ≥3 minutes after recording starts. *Contested: reported false on pre-A10 devices, an undocumented gate; also reported returning nil indefinitely on some iPhones.*
11. **`print(request.knownClassifications.count)` for `SNClassifySoundRequest(classifierIdentifier: .version1)` still returns 303 on iOS 26.** *The label roster is a community dump from iOS 15.0; a stable identifier does not prove a stable model.*
12. **`SNAudioStreamAnalyzer` classification runs in the background with `UIBackgroundModes: [audio]` alone**, or requires `processing` as well. *iOS 18.0–18.1 threw "Insufficient Permission (to submit GPU work from background)"; reported fixed in 18.2, but the underlying GPU-from-background restriction persists.*
13. **`CMAbsoluteAltitudeData.altitude` still fuses barometer with GNSS**, rather than collapsing to exactly the GPS altitude. *Forum 751610 (iOS 17.4.1+) reports the fusion dropped; no Apple engineer replied.*
14. **`UIDevice.batteryLevel` is still quantized to 5% on iOS 26** (was 1% on iOS 16 and earlier). *Undocumented regression; four forum threads, no Apple acknowledgement.*
15. **`CLVisit` events fire correctly when Precise Location is OFF** (Apple documents reduced-accuracy visit monitoring), and I can measure the median arrival→event latency. *Apple publishes no accuracy or latency figure for CLVisit anywhere.*
16. **`MKReverseGeocodingRequest` throttles at ~50 requests/60 s** and surfaces the failure as `MKError.loadingThrottled`. *Apple documents no limit; the only evidence is a hedged DTS reply and a developer-captured server string.*

### Free-tier routes worth confirming

17. **The iOS 26 Shortcuts action `Screen Time > Get App & Website Data` runs on this device, returns per-app durations, and its output can be piped into a background `AppIntent` with `supportedModes: [.background]` without showing a banner.** *This is the single highest-value Tier 0 finding and it is one action away from being confirmed or killed.*
18. **`~/Library/Biome/streams/restricted/App.InFocus/` can be extracted from a Windows iTunes backup.** *ASTER's README claims it; grepping every `.py` in the repo for `backup|MobileSync|Manifest.db|itunes` returns zero hits, and only the macOS Biome path is implemented. **A backup already exists on the Windows machine — this is a cheap test with an enormous payoff.***
19. **Shortcuts automations for Wi-Fi, Bluetooth, Message, Email and Transaction can be set to Run Immediately with "Notify When Run" OFF on iOS 26.** *Apple's iOS 26 guide lists 20 triggers as runnable automatically and states "The automation will not notify you when it's triggered." Cassinelli's first-hand iOS 17 reporting says those seven **always** notify and the toggle does not appear. The same Apple page names "Do Not Disturb" as a trigger while the Settings-triggers page calls it "Focus" — proving the list is stale and its silence is not authoritative.* **This decides whether dozens of automations are viable or unusable.**
20. **Disabling Shortcuts notifications in Settings does NOT stop automations from firing.** *A live iOS 27-beta counter-report says it kills Wi-Fi and location automations entirely, with multiple confirmations in-thread.*
21. **`SetFocusFilterIntent` fires on every Focus transition with no banner and no automation**, and its `@Parameter` values arrive intact.

### Nice-to-have

22. **`HKHeartbeatSeriesSample` returns non-empty beat series from this Apple Watch**, and the sample count matches expectation for Breathe/Mindfulness sessions.
23. **The Health app export's `<Me>` element contains `HKCharacteristicTypeIdentifierCardioFitnessMedicationsUse`** — as far as the research can determine, the only datum obtainable ONLY via export, with no API counterpart in any SDK.
24. **`DeviceActivityData.activityData(filteredBy:using:)` (iOS 26.4) throws on a US Apple Account in Dallas.** *Apple's wording is self-contradictory: "You can develop and test… on devices in any region" vs "Customer installations… can only use the method on devices located in the EU." Only relevant if you pay the $99.*
25. **The 20-condition `CLMonitor` cap rotates cleanly under load** without `conditionLimitExceeded` firing on every SLC event.

---

## ONE-PARAGRAPH VERDICT

**Build Tier 0 first, on a free Apple ID, in a public GitHub repo, with Sideloadly on a weekly cadence — and settle Probe Tests #1–3 in the first five days, because HealthKit signability is the hinge the whole design turns on.** If HealthKit signs, Tier 0 gives you years of retroactive health, a decade of geotagged photos, every GPS route you've ever run, 7 days of rolling motion, 3 days of raw 50 Hz accelerometer captured while your app wasn't running, continuous place logging with relaunch-on-termination, per-app screen time via a free Shortcuts action, ambient sound classification, and 86 years of weather to join against all of it — for $0 in entitlements and one Info.plist of usage strings. **Then pay the $99, not for Family Controls or WeatherKit or Wi-Fi info, but for the 1-year provisioning profile** — because the 7-day expiry does not degrade gracefully in this domain, it fails silently, and silence is indistinguishable from "the user did nothing."