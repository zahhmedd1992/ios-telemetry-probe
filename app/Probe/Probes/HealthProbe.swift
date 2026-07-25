import Foundation
import HealthKit

// ============================================================================
// HealthProbe — "what does THIS phone's Health database actually contain?"
//
// Everything in HealthKit is addressed by a string identifier. The catalog
// below is the COMPLETE set of those identifiers as published by Apple on
// developer.apple.com (verified 2026-07-24): 120 quantity types, 72 category
// types, 6 characteristic types, plus correlations, series, documents,
// clinical records and the one-off types (workout, workout route, heartbeat
// series, ECG, audiogram, state of mind, scored assessments, vision
// prescription, activity summary, medications).
//
// The catalog is stored as RAW STRINGS on purpose. Every type is materialised
// through the failable `…Type(forIdentifier:)` family, so an identifier that
// this OS has never heard of resolves to nil and is reported `.unavailable`
// instead of trapping. That is what lets this file safely ship identifiers
// that are NEWER than the device it runs on (e.g. the iOS 27 beta entries) —
// the catalog can lead the OS and the probe still degrades cleanly.
//
// The finding this probe exists to produce is not "HealthKit is available".
// It is: for each of ~200 metrics, does a sample exist, what is its value,
// HOW FAR BACK does the data actually go on first authorization, and WHICH
// device wrote it. That decides the collector schema.
// ============================================================================

// MARK: - Catalog

enum HealthProbeCatalog {

    /// Every HKQuantityTypeIdentifier (120 identifiers, verified against developer.apple.com 2026-07-24).
    static let quantity: [String] = [
        // --- Activity
        "HKQuantityTypeIdentifierStepCount",
        "HKQuantityTypeIdentifierDistanceWalkingRunning",
        "HKQuantityTypeIdentifierRunningGroundContactTime",  // iOS 16.0
        "HKQuantityTypeIdentifierRunningPower",  // iOS 16.0
        "HKQuantityTypeIdentifierRunningSpeed",  // iOS 16.0
        "HKQuantityTypeIdentifierRunningStrideLength",  // iOS 16.0
        "HKQuantityTypeIdentifierRunningVerticalOscillation",  // iOS 16.0
        "HKQuantityTypeIdentifierDistanceCycling",
        "HKQuantityTypeIdentifierPushCount",  // iOS 10.0
        "HKQuantityTypeIdentifierDistanceWheelchair",  // iOS 10.0
        "HKQuantityTypeIdentifierSwimmingStrokeCount",  // iOS 10.0
        "HKQuantityTypeIdentifierDistanceSwimming",  // iOS 10.0
        "HKQuantityTypeIdentifierDistanceDownhillSnowSports",  // iOS 11.2
        "HKQuantityTypeIdentifierBasalEnergyBurned",
        "HKQuantityTypeIdentifierActiveEnergyBurned",
        "HKQuantityTypeIdentifierFlightsClimbed",
        "HKQuantityTypeIdentifierNikeFuel",
        "HKQuantityTypeIdentifierAppleExerciseTime",  // iOS 9.3
        "HKQuantityTypeIdentifierAppleMoveTime",  // iOS 14.5
        "HKQuantityTypeIdentifierAppleStandTime",  // iOS 13.0
        "HKQuantityTypeIdentifierVO2Max",  // iOS 11.0
        "HKQuantityTypeIdentifierCrossCountrySkiingSpeed",  // iOS 18.0
        "HKQuantityTypeIdentifierCyclingCadence",  // iOS 17.0
        "HKQuantityTypeIdentifierCyclingFunctionalThresholdPower",  // iOS 17.0
        "HKQuantityTypeIdentifierCyclingPower",  // iOS 17.0
        "HKQuantityTypeIdentifierCyclingSpeed",  // iOS 17.0
        "HKQuantityTypeIdentifierDistanceCrossCountrySkiing",  // iOS 18.0
        "HKQuantityTypeIdentifierDistancePaddleSports",  // iOS 18.0
        "HKQuantityTypeIdentifierDistanceRowing",  // iOS 18.0
        "HKQuantityTypeIdentifierDistanceSkatingSports",  // iOS 18.0
        "HKQuantityTypeIdentifierEstimatedWorkoutEffortScore",  // iOS 18.0
        "HKQuantityTypeIdentifierPaddleSportsSpeed",  // iOS 18.0
        "HKQuantityTypeIdentifierPhysicalEffort",  // iOS 17.0
        "HKQuantityTypeIdentifierRowingSpeed",  // iOS 18.0
        "HKQuantityTypeIdentifierWorkoutEffortScore",  // iOS 18.0
        // --- Body measurements
        "HKQuantityTypeIdentifierHeight",
        "HKQuantityTypeIdentifierBodyMass",
        "HKQuantityTypeIdentifierBodyMassIndex",
        "HKQuantityTypeIdentifierLeanBodyMass",
        "HKQuantityTypeIdentifierBodyFatPercentage",
        "HKQuantityTypeIdentifierWaistCircumference",  // iOS 11.0
        "HKQuantityTypeIdentifierAppleSleepingWristTemperature",  // iOS 16.0
        // --- Reproductive health
        "HKQuantityTypeIdentifierBasalBodyTemperature",  // iOS 9.0
        // --- Hearing
        "HKQuantityTypeIdentifierEnvironmentalAudioExposure",  // iOS 13.0
        "HKQuantityTypeIdentifierEnvironmentalSoundReduction",  // iOS 16.0
        "HKQuantityTypeIdentifierHeadphoneAudioExposure",  // iOS 13.0
        // --- Vital signs
        "HKQuantityTypeIdentifierHeartRate",
        "HKQuantityTypeIdentifierRestingHeartRate",  // iOS 11.0
        "HKQuantityTypeIdentifierWalkingHeartRateAverage",  // iOS 11.0
        "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",  // iOS 11.0
        "HKQuantityTypeIdentifierHeartRateRecoveryOneMinute",  // iOS 16.0
        "HKQuantityTypeIdentifierAtrialFibrillationBurden",  // iOS 16.0
        "HKQuantityTypeIdentifierOxygenSaturation",
        "HKQuantityTypeIdentifierBodyTemperature",
        "HKQuantityTypeIdentifierBloodPressureDiastolic",
        "HKQuantityTypeIdentifierBloodPressureSystolic",
        "HKQuantityTypeIdentifierRespiratoryRate",
        // --- Lab and test results
        "HKQuantityTypeIdentifierBloodGlucose",
        "HKQuantityTypeIdentifierElectrodermalActivity",
        "HKQuantityTypeIdentifierForcedExpiratoryVolume1",
        "HKQuantityTypeIdentifierForcedVitalCapacity",
        "HKQuantityTypeIdentifierInhalerUsage",
        "HKQuantityTypeIdentifierInsulinDelivery",  // iOS 11.0
        "HKQuantityTypeIdentifierNumberOfTimesFallen",
        "HKQuantityTypeIdentifierPeakExpiratoryFlowRate",
        "HKQuantityTypeIdentifierPeripheralPerfusionIndex",
        // --- Nutrition
        "HKQuantityTypeIdentifierDietaryBiotin",
        "HKQuantityTypeIdentifierDietaryCaffeine",
        "HKQuantityTypeIdentifierDietaryCalcium",
        "HKQuantityTypeIdentifierDietaryCarbohydrates",
        "HKQuantityTypeIdentifierDietaryChloride",
        "HKQuantityTypeIdentifierDietaryCholesterol",
        "HKQuantityTypeIdentifierDietaryChromium",
        "HKQuantityTypeIdentifierDietaryCopper",
        "HKQuantityTypeIdentifierDietaryEnergyConsumed",
        "HKQuantityTypeIdentifierDietaryFatMonounsaturated",
        "HKQuantityTypeIdentifierDietaryFatPolyunsaturated",
        "HKQuantityTypeIdentifierDietaryFatSaturated",
        "HKQuantityTypeIdentifierDietaryFatTotal",
        "HKQuantityTypeIdentifierDietaryFiber",
        "HKQuantityTypeIdentifierDietaryFolate",
        "HKQuantityTypeIdentifierDietaryIodine",
        "HKQuantityTypeIdentifierDietaryIron",
        "HKQuantityTypeIdentifierDietaryMagnesium",
        "HKQuantityTypeIdentifierDietaryManganese",
        "HKQuantityTypeIdentifierDietaryMolybdenum",
        "HKQuantityTypeIdentifierDietaryNiacin",
        "HKQuantityTypeIdentifierDietaryPantothenicAcid",
        "HKQuantityTypeIdentifierDietaryPhosphorus",
        "HKQuantityTypeIdentifierDietaryPotassium",
        "HKQuantityTypeIdentifierDietaryProtein",
        "HKQuantityTypeIdentifierDietaryRiboflavin",
        "HKQuantityTypeIdentifierDietarySelenium",
        "HKQuantityTypeIdentifierDietarySodium",
        "HKQuantityTypeIdentifierDietarySugar",
        "HKQuantityTypeIdentifierDietaryThiamin",
        "HKQuantityTypeIdentifierDietaryVitaminA",
        "HKQuantityTypeIdentifierDietaryVitaminB12",
        "HKQuantityTypeIdentifierDietaryVitaminB6",
        "HKQuantityTypeIdentifierDietaryVitaminC",
        "HKQuantityTypeIdentifierDietaryVitaminD",
        "HKQuantityTypeIdentifierDietaryVitaminE",
        "HKQuantityTypeIdentifierDietaryVitaminK",
        "HKQuantityTypeIdentifierDietaryWater",  // iOS 9.0
        "HKQuantityTypeIdentifierDietaryZinc",
        // --- Alcohol consumption
        "HKQuantityTypeIdentifierBloodAlcoholContent",
        "HKQuantityTypeIdentifierNumberOfAlcoholicBeverages",  // iOS 15.0
        // --- Mobility
        "HKQuantityTypeIdentifierAppleWalkingSteadiness",  // iOS 15.0
        "HKQuantityTypeIdentifierSixMinuteWalkTestDistance",  // iOS 14.0
        "HKQuantityTypeIdentifierWalkingSpeed",  // iOS 14.0
        "HKQuantityTypeIdentifierWalkingStepLength",  // iOS 14.0
        "HKQuantityTypeIdentifierWalkingAsymmetryPercentage",  // iOS 14.0
        "HKQuantityTypeIdentifierWalkingDoubleSupportPercentage",  // iOS 14.0
        "HKQuantityTypeIdentifierStairAscentSpeed",  // iOS 14.0
        "HKQuantityTypeIdentifierStairDescentSpeed",  // iOS 14.0
        // --- UV exposure
        "HKQuantityTypeIdentifierTimeInDaylight",  // iOS 17.0
        "HKQuantityTypeIdentifierUVExposure",  // iOS 9.0
        // --- Diving
        "HKQuantityTypeIdentifierUnderwaterDepth",  // iOS 16.0
        "HKQuantityTypeIdentifierWaterTemperature",  // iOS 16.0
        // --- Type Properties
        "HKQuantityTypeIdentifierAppleSleepingBreathingDisturbances",  // iOS 18.0
    ]

    /// Every HKCategoryTypeIdentifier (72 identifiers, verified against developer.apple.com 2026-07-24).
    static let category: [String] = [
        // --- Activity
        "HKCategoryTypeIdentifierAppleStandHour",  // iOS 9.0
        "HKCategoryTypeIdentifierLowCardioFitnessEvent",  // iOS 14.3
        // --- Reproductive Health
        "HKCategoryTypeIdentifierMenstrualFlow",  // iOS 9.0
        "HKCategoryTypeIdentifierIntermenstrualBleeding",  // iOS 9.0
        "HKCategoryTypeIdentifierInfrequentMenstrualCycles",  // iOS 16.0
        "HKCategoryTypeIdentifierIrregularMenstrualCycles",  // iOS 16.0
        "HKCategoryTypeIdentifierPersistentIntermenstrualBleeding",  // iOS 16.0
        "HKCategoryTypeIdentifierProlongedMenstrualPeriods",  // iOS 16.0
        "HKCategoryTypeIdentifierCervicalMucusQuality",  // iOS 9.0
        "HKCategoryTypeIdentifierOvulationTestResult",  // iOS 9.0
        "HKCategoryTypeIdentifierProgesteroneTestResult",  // iOS 15.0
        "HKCategoryTypeIdentifierSexualActivity",  // iOS 9.0
        "HKCategoryTypeIdentifierContraceptive",  // iOS 14.3
        "HKCategoryTypeIdentifierPregnancy",  // iOS 14.3
        "HKCategoryTypeIdentifierPregnancyTestResult",  // iOS 15.0
        "HKCategoryTypeIdentifierLactation",  // iOS 14.3
        "HKCategoryTypeIdentifierMenopausalState",  // iOS 27.0 per current docs (page re-versioned)
        "HKCategoryTypeIdentifierBleedingAfterMenopause",  // iOS 27.0 per current docs (page re-versioned)
        // --- Hearing
        "HKCategoryTypeIdentifierEnvironmentalAudioExposureEvent",  // iOS 14.0
        "HKCategoryTypeIdentifierHeadphoneAudioExposureEvent",  // iOS 14.2
        "HKCategoryTypeIdentifierAudioExposureEvent",  // iOS 13.0
        // --- Vital Signs
        "HKCategoryTypeIdentifierLowHeartRateEvent",  // iOS 12.2
        "HKCategoryTypeIdentifierHighHeartRateEvent",  // iOS 12.2
        "HKCategoryTypeIdentifierIrregularHeartRhythmEvent",  // iOS 12.2
        // --- Mobility
        "HKCategoryTypeIdentifierAppleWalkingSteadinessEvent",  // iOS 15.0
        // --- Mindfulness and Sleep
        "HKCategoryTypeIdentifierMindfulSession",  // iOS 10.0
        "HKCategoryTypeIdentifierSleepAnalysis",
        // --- Self Care
        "HKCategoryTypeIdentifierToothbrushingEvent",  // iOS 13.0
        "HKCategoryTypeIdentifierHandwashingEvent",  // iOS 14.0
        // --- Type Properties generated
        "HKCategoryTypeIdentifierHypertensionEvent",  // iOS 26.2
        // --- Abdominal and Gastrointestinal
        "HKCategoryTypeIdentifierAbdominalCramps",  // iOS 13.6
        "HKCategoryTypeIdentifierBloating",  // iOS 13.6
        "HKCategoryTypeIdentifierConstipation",  // iOS 13.6
        "HKCategoryTypeIdentifierDiarrhea",  // iOS 13.6
        "HKCategoryTypeIdentifierHeartburn",  // iOS 13.6
        "HKCategoryTypeIdentifierNausea",  // iOS 13.6
        "HKCategoryTypeIdentifierVomiting",  // iOS 13.6
        // --- Constitutional
        "HKCategoryTypeIdentifierAppetiteChanges",  // iOS 13.6
        "HKCategoryTypeIdentifierChills",  // iOS 13.6
        "HKCategoryTypeIdentifierDizziness",  // iOS 13.6
        "HKCategoryTypeIdentifierFainting",  // iOS 13.6
        "HKCategoryTypeIdentifierFatigue",  // iOS 13.6
        "HKCategoryTypeIdentifierFever",  // iOS 13.6
        "HKCategoryTypeIdentifierGeneralizedBodyAche",  // iOS 13.6
        "HKCategoryTypeIdentifierHotFlashes",  // iOS 13.6
        // --- Heart and Lung
        "HKCategoryTypeIdentifierChestTightnessOrPain",  // iOS 13.6
        "HKCategoryTypeIdentifierCoughing",  // iOS 13.6
        "HKCategoryTypeIdentifierRapidPoundingOrFlutteringHeartbeat",  // iOS 13.6
        "HKCategoryTypeIdentifierShortnessOfBreath",  // iOS 13.6
        "HKCategoryTypeIdentifierSkippedHeartbeat",  // iOS 13.6
        "HKCategoryTypeIdentifierWheezing",  // iOS 13.6
        // --- Musculoskeletal
        "HKCategoryTypeIdentifierLowerBackPain",  // iOS 13.6
        // --- Neurological
        "HKCategoryTypeIdentifierHeadache",  // iOS 13.6
        "HKCategoryTypeIdentifierMemoryLapse",  // iOS 14.0
        "HKCategoryTypeIdentifierMoodChanges",  // iOS 13.6
        // --- Nose and Throat
        "HKCategoryTypeIdentifierLossOfSmell",  // iOS 13.6
        "HKCategoryTypeIdentifierLossOfTaste",  // iOS 13.6
        "HKCategoryTypeIdentifierRunnyNose",  // iOS 13.6
        "HKCategoryTypeIdentifierSoreThroat",  // iOS 13.6
        "HKCategoryTypeIdentifierSinusCongestion",  // iOS 13.6
        // --- Reproduction
        "HKCategoryTypeIdentifierBreastPain",  // iOS 13.6
        "HKCategoryTypeIdentifierPelvicPain",  // iOS 13.6
        "HKCategoryTypeIdentifierVaginalDryness",  // iOS 14.0
        // --- Skin and Hair
        "HKCategoryTypeIdentifierAcne",  // iOS 13.6
        "HKCategoryTypeIdentifierDrySkin",  // iOS 14.0
        "HKCategoryTypeIdentifierHairLoss",  // iOS 14.0
        // --- Sleep
        "HKCategoryTypeIdentifierNightSweats",  // iOS 14.0
        "HKCategoryTypeIdentifierSleepChanges",  // iOS 13.6
        // --- Urinary
        "HKCategoryTypeIdentifierBladderIncontinence",  // iOS 14.0
        // --- not grouped by the current doc index
        "HKCategoryTypeIdentifierBleedingAfterPregnancy",  // iOS 18.0
        "HKCategoryTypeIdentifierBleedingDuringPregnancy",  // iOS 18.0
        "HKCategoryTypeIdentifierSleepApneaEvent",  // iOS 18.0
    ]
    /// Every HKCharacteristicTypeIdentifier (6 identifiers).
    static let characteristic: [String] = [
        "HKCharacteristicTypeIdentifierDateOfBirth",
        "HKCharacteristicTypeIdentifierBiologicalSex",
        "HKCharacteristicTypeIdentifierBloodType",
        "HKCharacteristicTypeIdentifierFitzpatrickSkinType",
        "HKCharacteristicTypeIdentifierWheelchairUse",  // iOS 10.0
        "HKCharacteristicTypeIdentifierActivityMoveMode"  // iOS 14.0
    ]

    /// Every HKCorrelationTypeIdentifier (2 identifiers).
    static let correlation: [String] = [
        "HKCorrelationTypeIdentifierBloodPressure",
        "HKCorrelationTypeIdentifierFood"
    ]

    /// Every HKSeriesType identifier. Note `seriesType(forIdentifier:)` takes a
    /// plain String, not a wrapper struct — unlike every other family here.
    static let series: [String] = [
        "HKWorkoutRouteTypeIdentifier",     // iOS 11.0
        "HKDataTypeIdentifierHeartbeatSeries"  // iOS 13.0
    ]

    /// Every HKDocumentTypeIdentifier.
    static let document: [String] = [
        "HKDocumentTypeIdentifierCDA"  // iOS 10.0
    ]

    /// Every HKClinicalTypeIdentifier. Reading ANY of these requires the
    /// `com.apple.developer.healthkit.access` entitlement, which Apple grants
    /// per-app; a sideloaded build normally does not have it.
    static let clinical: [String] = [
        "HKClinicalTypeIdentifierAllergyRecord",        // iOS 12.0
        "HKClinicalTypeIdentifierConditionRecord",      // iOS 12.0
        "HKClinicalTypeIdentifierImmunizationRecord",   // iOS 12.0
        "HKClinicalTypeIdentifierLabResultRecord",      // iOS 12.0
        "HKClinicalTypeIdentifierMedicationRecord",     // iOS 12.0
        "HKClinicalTypeIdentifierProcedureRecord",      // iOS 12.0
        "HKClinicalTypeIdentifierVitalSignRecord",      // iOS 12.0
        "HKClinicalTypeIdentifierCoverageRecord",       // iOS 16.0
        "HKClinicalTypeIdentifierClinicalNoteRecord"    // iOS 16.4
    ]

    /// Human label for an identifier: strip the framework prefix.
    static func label(_ identifier: String) -> String {
        for prefix in ["HKQuantityTypeIdentifier", "HKCategoryTypeIdentifier",
                       "HKCharacteristicTypeIdentifier", "HKCorrelationTypeIdentifier",
                       "HKClinicalTypeIdentifier", "HKDocumentTypeIdentifier",
                       "HKDataTypeIdentifier"] where identifier.hasPrefix(prefix) {
            return String(identifier.dropFirst(prefix.count))
        }
        return identifier
    }
}

// MARK: - Units
//
// HKUnit(from:) raises an Objective-C exception on a malformed string, and
// Swift cannot catch that — it is an uncatchable trap, not a Swift error. So
// every unit here is built from the type-checked factory methods instead, and
// before any conversion we ask HKQuantity.is(compatibleWith:) whether the
// conversion is legal. That check IS the do/catch: it is the only faithful way
// to guarantee `doubleValue(for:)` cannot trap. Do not "simplify" it back to a
// try/catch — a Swift catch block would never fire.

enum HealthProbeUnits {
    static let count = HKUnit.count()
    static let perMinute = HKUnit.count().unitDivided(by: HKUnit.minute())
    static let meter = HKUnit.meter()
    static let centimeter = HKUnit.meterUnit(with: .centi)
    static let kilocalorie = HKUnit.kilocalorie()
    static let kilogram = HKUnit.gramUnit(with: .kilo)
    static let gram = HKUnit.gram()
    static let milligram = HKUnit.gramUnit(with: .milli)
    static let microgram = HKUnit.gramUnit(with: .micro)
    static let percent = HKUnit.percent()
    static let degC = HKUnit.degreeCelsius()
    static let mmHg = HKUnit.millimeterOfMercury()
    static let millisecond = HKUnit.secondUnit(with: .milli)
    static let second = HKUnit.second()
    static let minute = HKUnit.minute()
    static let hour = HKUnit.hour()
    static let liter = HKUnit.liter()
    static let milliliter = HKUnit.literUnit(with: .milli)
    static let literPerMinute = HKUnit.liter().unitDivided(by: HKUnit.minute())
    static let mgPerDL = HKUnit.gramUnit(with: .milli)
        .unitDivided(by: HKUnit.literUnit(with: .deci))
    static let mlPerKgMin = HKUnit.literUnit(with: .milli)
        .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: HKUnit.minute()))
    static let dbaspl = HKUnit.decibelAWeightedSoundPressureLevel()
    static let dbhl = HKUnit.decibelHearingLevel()
    static let watt = HKUnit.watt()
    static let meterPerSecond = HKUnit.meter().unitDivided(by: HKUnit.second())
    static let internationalUnit = HKUnit.internationalUnit()
    static let microsiemens = HKUnit.siemenUnit(with: .micro)
    static let kcalPerKgHour = HKUnit.kilocalorie()
        .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: HKUnit.hour()))

    /// Fallback probe order, used when neither HealthKit's own preferred unit
    /// nor the static map below produced a compatible unit.
    static var candidates: [HKUnit] {
        var c: [HKUnit] = [count, perMinute, percent, meter, kilocalorie, kilogram,
                           degC, mmHg, millisecond, minute, hour, second,
                           liter, literPerMinute, mgPerDL, mlPerKgMin,
                           dbaspl, dbhl, watt, meterPerSecond, internationalUnit,
                           microsiemens, gram, milligram, microgram, milliliter,
                           kcalPerKgHour]
        if #available(iOS 18.0, *) { c.append(HKUnit.appleEffortScore()) }
        return c
    }

    /// Sensible display unit per quantity family. Only a fallback — at runtime
    /// we prefer whatever `HKHealthStore.preferredUnits(for:)` reports, because
    /// that is the unit THIS user's Health app is actually configured for.
    static let byIdentifier: [String: HKUnit] = {
        var m: [String: HKUnit] = [:]
        func set(_ u: HKUnit, _ ids: [String]) { for i in ids { m["HKQuantityTypeIdentifier" + i] = u } }

        set(count, ["StepCount", "FlightsClimbed", "PushCount", "SwimmingStrokeCount",
                    "NikeFuel", "InhalerUsage", "NumberOfTimesFallen",
                    "NumberOfAlcoholicBeverages", "BodyMassIndex", "UVExposure",
                    "AppleSleepingBreathingDisturbances"])
        set(perMinute, ["HeartRate", "RestingHeartRate", "WalkingHeartRateAverage",
                        "RespiratoryRate", "HeartRateRecoveryOneMinute", "CyclingCadence"])
        set(meter, ["DistanceWalkingRunning", "DistanceCycling", "DistanceSwimming",
                    "DistanceWheelchair", "DistanceDownhillSnowSports",
                    "DistanceCrossCountrySkiing", "DistancePaddleSports",
                    "DistanceRowing", "DistanceSkatingSports",
                    "SixMinuteWalkTestDistance", "UnderwaterDepth", "RunningStrideLength"])
        set(centimeter, ["Height", "WaistCircumference", "WalkingStepLength",
                         "RunningVerticalOscillation"])
        set(kilocalorie, ["ActiveEnergyBurned", "BasalEnergyBurned", "DietaryEnergyConsumed"])
        set(minute, ["AppleExerciseTime", "AppleMoveTime", "AppleStandTime", "TimeInDaylight"])
        set(millisecond, ["HeartRateVariabilitySDNN", "RunningGroundContactTime"])
        set(percent, ["OxygenSaturation", "BodyFatPercentage", "WalkingAsymmetryPercentage",
                      "WalkingDoubleSupportPercentage", "AppleWalkingSteadiness",
                      "AtrialFibrillationBurden", "PeripheralPerfusionIndex",
                      "BloodAlcoholContent"])
        set(degC, ["BodyTemperature", "BasalBodyTemperature",
                   "AppleSleepingWristTemperature", "WaterTemperature"])
        set(mmHg, ["BloodPressureSystolic", "BloodPressureDiastolic"])
        set(kilogram, ["BodyMass", "LeanBodyMass"])
        set(mlPerKgMin, ["VO2Max"])
        set(liter, ["ForcedVitalCapacity", "ForcedExpiratoryVolume1"])
        set(literPerMinute, ["PeakExpiratoryFlowRate"])
        set(mgPerDL, ["BloodGlucose"])
        set(internationalUnit, ["InsulinDelivery"])
        set(microsiemens, ["ElectrodermalActivity"])
        set(dbaspl, ["EnvironmentalAudioExposure", "HeadphoneAudioExposure",
                     "EnvironmentalSoundReduction"])
        set(meterPerSecond, ["WalkingSpeed", "StairAscentSpeed", "StairDescentSpeed",
                             "RunningSpeed", "CyclingSpeed", "RowingSpeed",
                             "PaddleSportsSpeed", "CrossCountrySkiingSpeed"])
        set(watt, ["RunningPower", "CyclingPower", "CyclingFunctionalThresholdPower"])
        set(kcalPerKgHour, ["PhysicalEffort"])
        set(gram, ["DietaryCarbohydrates", "DietaryFatTotal", "DietaryFatSaturated",
                   "DietaryFatMonounsaturated", "DietaryFatPolyunsaturated",
                   "DietaryProtein", "DietaryFiber", "DietarySugar"])
        set(milligram, ["DietaryCholesterol", "DietarySodium", "DietaryCalcium",
                        "DietaryIron", "DietaryMagnesium", "DietaryPotassium",
                        "DietaryVitaminC", "DietaryVitaminE", "DietaryNiacin",
                        "DietaryPantothenicAcid", "DietaryPhosphorus", "DietaryZinc",
                        "DietaryCaffeine", "DietaryChloride", "DietaryThiamin",
                        "DietaryRiboflavin", "DietaryVitaminB6", "DietaryManganese"])
        set(microgram, ["DietaryBiotin", "DietaryChromium", "DietaryCopper",
                        "DietaryFolate", "DietaryIodine", "DietaryMolybdenum",
                        "DietarySelenium", "DietaryVitaminB12", "DietaryVitaminK",
                        "DietaryVitaminA", "DietaryVitaminD"])
        set(milliliter, ["DietaryWater"])
        if #available(iOS 18.0, *) {
            set(HKUnit.appleEffortScore(), ["WorkoutEffortScore", "EstimatedWorkoutEffortScore"])
        }
        return m
    }()
}

// MARK: - Workout activity type names
//
// HKWorkoutActivityType is an ObjC NS_ENUM whose raw values Apple does not
// publish. Building the map from the compile-time cases means the numbers can
// never drift. All 84 cases below are iOS 17.0 or earlier, so the literal is
// safe against the 17.0 deployment target.

enum HealthProbeWorkoutNames {
    static let byRawValue: [UInt: String] = {
        let pairs: [(HKWorkoutActivityType, String)] = [
        (.americanFootball, "americanFootball"), (.archery, "archery"), (.australianFootball, "australianFootball"), (.badminton, "badminton"),
        (.barre, "barre"), (.baseball, "baseball"), (.basketball, "basketball"), (.bowling, "bowling"),
        (.boxing, "boxing"), (.cardioDance, "cardioDance"), (.climbing, "climbing"), (.cooldown, "cooldown"),
        (.coreTraining, "coreTraining"), (.cricket, "cricket"), (.crossCountrySkiing, "crossCountrySkiing"), (.crossTraining, "crossTraining"),
        (.curling, "curling"), (.cycling, "cycling"), (.dance, "dance"), (.danceInspiredTraining, "danceInspiredTraining"),
        (.discSports, "discSports"), (.downhillSkiing, "downhillSkiing"), (.elliptical, "elliptical"), (.equestrianSports, "equestrianSports"),
        (.fencing, "fencing"), (.fishing, "fishing"), (.fitnessGaming, "fitnessGaming"), (.flexibility, "flexibility"),
        (.functionalStrengthTraining, "functionalStrengthTraining"), (.golf, "golf"), (.gymnastics, "gymnastics"), (.handCycling, "handCycling"),
        (.handball, "handball"), (.highIntensityIntervalTraining, "highIntensityIntervalTraining"), (.hiking, "hiking"), (.hockey, "hockey"),
        (.hunting, "hunting"), (.jumpRope, "jumpRope"), (.kickboxing, "kickboxing"), (.lacrosse, "lacrosse"),
        (.martialArts, "martialArts"), (.mindAndBody, "mindAndBody"), (.mixedCardio, "mixedCardio"), (.mixedMetabolicCardioTraining, "mixedMetabolicCardioTraining"),
        (.other, "other"), (.paddleSports, "paddleSports"), (.pickleball, "pickleball"), (.pilates, "pilates"),
        (.play, "play"), (.preparationAndRecovery, "preparationAndRecovery"), (.racquetball, "racquetball"), (.rowing, "rowing"),
        (.rugby, "rugby"), (.running, "running"), (.sailing, "sailing"), (.skatingSports, "skatingSports"),
        (.snowSports, "snowSports"), (.snowboarding, "snowboarding"), (.soccer, "soccer"), (.socialDance, "socialDance"),
        (.softball, "softball"), (.squash, "squash"), (.stairClimbing, "stairClimbing"), (.stairs, "stairs"),
        (.stepTraining, "stepTraining"), (.surfingSports, "surfingSports"), (.swimBikeRun, "swimBikeRun"), (.swimming, "swimming"),
        (.tableTennis, "tableTennis"), (.taiChi, "taiChi"), (.tennis, "tennis"), (.trackAndField, "trackAndField"),
        (.traditionalStrengthTraining, "traditionalStrengthTraining"), (.transition, "transition"), (.underwaterDiving, "underwaterDiving"), (.volleyball, "volleyball"),
        (.walking, "walking"), (.waterFitness, "waterFitness"), (.waterPolo, "waterPolo"), (.waterSports, "waterSports"),
        (.wheelchairRunPace, "wheelchairRunPace"), (.wheelchairWalkPace, "wheelchairWalkPace"), (.wrestling, "wrestling"), (.yoga, "yoga"),
        ]
        var m: [UInt: String] = [:]
        for (t, n) in pairs { m[t.rawValue] = n }
        return m
    }()

    static func name(_ t: HKWorkoutActivityType) -> String {
        byRawValue[t.rawValue] ?? "activityType(\(t.rawValue))"
    }
}

// MARK: - Small utilities (all prefixed — this file shares a module with ten others)

/// One-shot guard so a delegate/handler that can fire more than once still
/// resumes its continuation exactly once.
final class HealthProbeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}

/// Thread-safe boolean, used to observe a handler firing without parking a
/// continuation that might never be resumed.
final class HealthProbeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    func set() { lock.lock(); v = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return v }
}

/// HKHealthStore is not Sendable; one shared instance is the documented usage.
/// Boxing it keeps the task-group closures clean without spawning 200 stores.
final class HealthProbeStoreBox: @unchecked Sendable {
    let store = HKHealthStore()
}

/// Everything we need out of a sample, flattened to value types at the moment
/// the completion handler runs, so nothing non-Sendable crosses a task boundary.
struct HealthProbeSampleInfo: Sendable {
    var start: Date
    var end: Date
    var sampleClass: String
    var valueText: String?
    var unitText: String?
    var coalescedCount: Int?
    var sourceName: String?
    var sourceBundle: String?
    var productType: String?
    var osVersion: String?
    var deviceModel: String?
    var deviceName: String?
    var deviceManufacturer: String?
    var deviceHardware: String?
    var deviceSoftware: String?
    var metadataKeys: [String]
    var notes: [String: String]
}

enum HealthProbeFetch: Sendable {
    case sample(HealthProbeSampleInfo)
    case empty
    case failed(String, Bool)   // message, looksLikeAuthorizationError
    case timedOut
}

enum HealthProbeCountResult: Sendable {
    case counted(Int, capped: Bool)
    case failed(String)
    case timedOut
}

struct HealthProbeWorkoutRow: Sendable {
    let activityRawValue: UInt
    let start: Date
    let end: Date
    let duration: TimeInterval
}

/// One unit of sweep work. `@unchecked Sendable` because HKSampleType/HKUnit
/// are immutable, thread-safe Apple objects that simply predate Sendable.
struct HealthProbeWork: @unchecked Sendable {
    let key: String
    let label: String
    let type: HKSampleType
    let unit: HKUnit?
}

// MARK: - Async wrappers around HealthKit's callback API

enum HealthProbeHK {

    static func isAuthError(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == HKError.errorDomain else { return false }
        switch ns.code {
        case HKError.errorAuthorizationDenied.rawValue,
             HKError.errorAuthorizationNotDetermined.rawValue:
            return true
        default:
            return false
        }
    }

    static func errorText(_ error: Error) -> String {
        let ns = error as NSError
        var s = "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
        if ns.domain == HKError.errorDomain,
           let code = HKError.Code(rawValue: ns.code) {
            s += " [\(String(describing: code))]"
        }
        return s
    }

    static func requestRead(_ store: HKHealthStore,
                            _ types: Set<HKObjectType>) async -> (Bool, String?) {
        await withCheckedContinuation { cont in
            let gate = HealthProbeGate()
            // HealthKit validates the requested type set SYNCHRONOUSLY and raises an
            // Objective-C exception — not a Swift error — for any type the app is not
            // permitted to ask about. Confirmed on device: a CDA document type in the
            // read set produced
            //   -[HKHealthStoreImplementation _throwIfAuthorizationDisallowedForSharing:types:]
            // and SIGABRT'd the whole app before one section was reported.
            //
            // The throw happens before the completion handler is ever scheduled, so the
            // continuation must be resumed on the failure path or the probe hangs forever.
            var reason: NSString?
            let completed = ProbeCatchNSException({
                store.requestAuthorization(toShare: Set<HKSampleType>(), read: types) { ok, err in
                    guard gate.claim() else { return }
                    cont.resume(returning: (ok, err.map { errorText($0) }))
                }
            }, &reason)

            if !completed {
                guard gate.claim() else { return }
                cont.resume(returning: (false, "Objective-C exception (caught): \(reason ?? "unknown")"))
            }
        }
    }

    static func preferredUnits(_ store: HKHealthStore,
                               _ types: Set<HKQuantityType>) async -> ([String: String], String?) {
        await withCheckedContinuation { (cont: CheckedContinuation<([String: String], String?), Never>) in
            let gate = HealthProbeGate()
            store.preferredUnits(for: types) { map, err in
                guard gate.claim() else { return }
                var out: [String: String] = [:]
                for (t, u) in map { out[t.identifier] = u.unitString }
                cont.resume(returning: (out, err.map { errorText($0) }))
            }
        }
    }

    /// Flatten one HKSample into value types. Never traps: unit conversion is
    /// gated on `is(compatibleWith:)`, and the last resort is HKQuantity's own
    /// `description`, which HealthKit renders in whatever unit it stored.
    static func describe(_ s: HKSample, unit: HKUnit?) -> HealthProbeSampleInfo {
        var valueText: String?
        var unitText: String?
        var coalesced: Int?
        var notes: [String: String] = [:]

        if let qs = s as? HKQuantitySample {
            let q = qs.quantity
            var chosen: HKUnit?
            if let unit, q.is(compatibleWith: unit) {
                chosen = unit
            } else {
                chosen = HealthProbeUnits.candidates.first { q.is(compatibleWith: $0) }
            }
            if let u = chosen {
                valueText = ProbeEnv.num(q.doubleValue(for: u)) + " " + u.unitString
                unitText = u.unitString
            } else {
                valueText = q.description
                unitText = "unknown (fell back to HKQuantity.description)"
            }
            coalesced = qs.count
        } else if let cs = s as? HKCategorySample {
            var text = "value=\(cs.value)"
            if cs.categoryType.identifier == "HKCategoryTypeIdentifierSleepAnalysis",
               let v = HKCategoryValueSleepAnalysis(rawValue: cs.value) {
                text += " (\(String(describing: v)))"
            }
            if cs.categoryType.identifier == "HKCategoryTypeIdentifierAppleStandHour",
               let v = HKCategoryValueAppleStandHour(rawValue: cs.value) {
                text += " (\(String(describing: v)))"
            }
            valueText = text
        } else if let w = s as? HKWorkout {
            valueText = HealthProbeWorkoutNames.name(w.workoutActivityType)
                + ", " + ProbeEnv.num(w.duration / 60) + " min"
            notes["workoutActivityType"] = HealthProbeWorkoutNames.name(w.workoutActivityType)
        } else if #available(iOS 18.0, *), let m = s as? HKStateOfMind {
            valueText = "valence " + ProbeEnv.num(m.valence)
                + " (" + String(describing: m.valenceClassification) + "), kind "
                + String(describing: m.kind)
            notes["valence"] = ProbeEnv.num(m.valence)
            notes["valenceClassification"] = String(describing: m.valenceClassification)
            notes["kind"] = String(describing: m.kind)
            notes["labelRawValues"] = m.labels.map { String($0.rawValue) }.joined(separator: ",")
            notes["associationRawValues"] = m.associations.map { String($0.rawValue) }.joined(separator: ",")
        } else if let e = s as? HKElectrocardiogram {
            var text = String(describing: e.classification)
            if let hr = e.averageHeartRate, hr.is(compatibleWith: HealthProbeUnits.perMinute) {
                text += ", avg " + ProbeEnv.num(hr.doubleValue(for: HealthProbeUnits.perMinute)) + " bpm"
            }
            valueText = text
            notes["classification"] = String(describing: e.classification)
            notes["symptomsStatus"] = String(describing: e.symptomsStatus)
            notes["numberOfVoltageMeasurements"] = ProbeEnv.int(e.numberOfVoltageMeasurements)
            if let f = e.samplingFrequency, f.is(compatibleWith: HKUnit.hertz()) {
                notes["samplingFrequencyHz"] = ProbeEnv.num(f.doubleValue(for: HKUnit.hertz()))
            }
        }

        let rev = s.sourceRevision
        let osv = rev.operatingSystemVersion
        return HealthProbeSampleInfo(
            start: s.startDate,
            end: s.endDate,
            sampleClass: String(describing: type(of: s)),
            valueText: valueText,
            unitText: unitText,
            coalescedCount: coalesced,
            sourceName: rev.source.name,
            sourceBundle: rev.source.bundleIdentifier,
            productType: rev.productType,
            osVersion: "\(osv.majorVersion).\(osv.minorVersion).\(osv.patchVersion)",
            deviceModel: s.device?.model,
            deviceName: s.device?.name,
            deviceManufacturer: s.device?.manufacturer,
            deviceHardware: s.device?.hardwareVersion,
            deviceSoftware: s.device?.softwareVersion,
            metadataKeys: (s.metadata?.keys.map { $0 } ?? []).sorted(),
            notes: notes
        )
    }

    /// Newest (ascending == false) or oldest (ascending == true) single sample.
    /// The oldest one is the point of the whole exercise: it is the only way to
    /// measure the REAL historical depth HealthKit hands over on first grant,
    /// which no Apple document states.
    static func firstSample(_ store: HKHealthStore,
                            type: HKSampleType,
                            ascending: Bool,
                            unit: HKUnit?,
                            timeout: Double) async -> HealthProbeFetch {
        await withProbeTimeout(timeout, fallback: HealthProbeFetch.timedOut) {
            await withCheckedContinuation { (cont: CheckedContinuation<HealthProbeFetch, Never>) in
                let gate = HealthProbeGate()
                let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate,
                                            ascending: ascending)
                let q = HKSampleQuery(sampleType: type,
                                      predicate: nil,
                                      limit: 1,
                                      sortDescriptors: [sort]) { _, results, err in
                    guard gate.claim() else { return }
                    if let err {
                        cont.resume(returning: .failed(errorText(err), isAuthError(err)))
                        return
                    }
                    guard let results, let s = results.first else {
                        cont.resume(returning: .empty)
                        return
                    }
                    cont.resume(returning: .sample(describe(s, unit: unit)))
                }
                store.execute(q)
            }
        }
    }

    /// Bounded density probe. Not a true count — it is "how many samples landed
    /// in the last `days` days, up to `cap`". That is exactly the number a
    /// collector needs to size its polling interval, and it is cheap.
    static func recentCount(_ store: HKHealthStore,
                            type: HKSampleType,
                            days: Double,
                            cap: Int,
                            timeout: Double) async -> HealthProbeCountResult {
        await withProbeTimeout(timeout, fallback: HealthProbeCountResult.timedOut) {
            await withCheckedContinuation { (cont: CheckedContinuation<HealthProbeCountResult, Never>) in
                let gate = HealthProbeGate()
                let start = Date().addingTimeInterval(-days * 86_400)
                let pred = HKQuery.predicateForSamples(withStart: start,
                                                       end: Date(),
                                                       options: [.strictStartDate])
                let q = HKSampleQuery(sampleType: type,
                                      predicate: pred,
                                      limit: cap,
                                      sortDescriptors: []) { _, results, err in
                    guard gate.claim() else { return }
                    if let err {
                        cont.resume(returning: .failed(errorText(err)))
                        return
                    }
                    let n = results?.count ?? 0
                    cont.resume(returning: .counted(n, capped: n >= cap))
                }
                store.execute(q)
            }
        }
    }

    /// HKSourceQuery is how we learn WHICH writer owns a metric — Watch vs
    /// phone vs a third-party app. Device model comes off the samples, since
    /// HKSource itself carries no hardware information.
    static func sources(_ store: HKHealthStore,
                        type: HKSampleType,
                        timeout: Double) async -> ([String], String?) {
        await withProbeTimeout(timeout, fallback: ([String](), "timed out" as String?)) {
            await withCheckedContinuation { (cont: CheckedContinuation<([String], String?), Never>) in
                let gate = HealthProbeGate()
                let q = HKSourceQuery(sampleType: type, samplePredicate: nil) { _, srcs, err in
                    guard gate.claim() else { return }
                    if let err {
                        cont.resume(returning: ([], errorText(err)))
                        return
                    }
                    let names = (srcs ?? []).map { "\($0.name) [\($0.bundleIdentifier)]" }.sorted()
                    cont.resume(returning: (names, nil))
                }
                store.execute(q)
            }
        }
    }

    static func activitySummaries(_ store: HKHealthStore,
                                  days: Int,
                                  timeout: Double) async -> ([[String: String]], String?) {
        await withProbeTimeout(timeout, fallback: ([[String: String]](), "timed out" as String?)) {
            await withCheckedContinuation { (cont: CheckedContinuation<([[String: String]], String?), Never>) in
                let gate = HealthProbeGate()
                var cal = Calendar(identifier: .gregorian)
                cal.timeZone = TimeZone.current
                let endDate = Date()
                let startDate = endDate.addingTimeInterval(-Double(days) * 86_400)
                var startComps = cal.dateComponents([.year, .month, .day], from: startDate)
                startComps.calendar = cal
                var endComps = cal.dateComponents([.year, .month, .day], from: endDate)
                endComps.calendar = cal
                let pred = HKQuery.predicate(forActivitySummariesBetweenStart: startComps,
                                             end: endComps)
                let q = HKActivitySummaryQuery(predicate: pred) { _, summaries, err in
                    guard gate.claim() else { return }
                    if let err {
                        cont.resume(returning: ([], errorText(err)))
                        return
                    }
                    var rows: [[String: String]] = []
                    for s in summaries ?? [] {
                        var r: [String: String] = [:]
                        let comps = s.dateComponents(for: cal)
                        if let d = cal.date(from: comps), let stamp = ProbeEnv.stamp(d) {
                            r["date"] = stamp
                        }
                        let kcal = HealthProbeUnits.kilocalorie
                        let mins = HealthProbeUnits.minute
                        let cnt = HealthProbeUnits.count
                        if s.activeEnergyBurned.is(compatibleWith: kcal) {
                            r["activeEnergyKcal"] = ProbeEnv.num(s.activeEnergyBurned.doubleValue(for: kcal))
                        }
                        if s.activeEnergyBurnedGoal.is(compatibleWith: kcal) {
                            r["moveGoalKcal"] = ProbeEnv.num(s.activeEnergyBurnedGoal.doubleValue(for: kcal))
                        }
                        if s.appleExerciseTime.is(compatibleWith: mins) {
                            r["exerciseMin"] = ProbeEnv.num(s.appleExerciseTime.doubleValue(for: mins))
                        }
                        if s.appleExerciseTimeGoal.is(compatibleWith: mins) {
                            r["exerciseGoalMin"] = ProbeEnv.num(s.appleExerciseTimeGoal.doubleValue(for: mins))
                        }
                        if s.appleStandHours.is(compatibleWith: cnt) {
                            r["standHours"] = ProbeEnv.num(s.appleStandHours.doubleValue(for: cnt))
                        }
                        if s.appleStandHoursGoal.is(compatibleWith: cnt) {
                            r["standGoalHours"] = ProbeEnv.num(s.appleStandHoursGoal.doubleValue(for: cnt))
                        }
                        rows.append(r)
                    }
                    cont.resume(returning: (rows, nil))
                }
                store.execute(q)
            }
        }
    }

    /// All workouts (bounded). Flattened inside the handler.
    static func workouts(_ store: HKHealthStore,
                         cap: Int,
                         timeout: Double) async -> ([HealthProbeWorkoutRow], String?, Bool) {
        await withProbeTimeout(timeout,
                               fallback: ([HealthProbeWorkoutRow](), "timed out" as String?, false)) {
            await withCheckedContinuation { (cont: CheckedContinuation<([HealthProbeWorkoutRow], String?, Bool), Never>) in
                let gate = HealthProbeGate()
                let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
                let q = HKSampleQuery(sampleType: HKObjectType.workoutType(),
                                      predicate: nil,
                                      limit: cap,
                                      sortDescriptors: [sort]) { _, results, err in
                    guard gate.claim() else { return }
                    if let err {
                        cont.resume(returning: ([], errorText(err), false))
                        return
                    }
                    var rows: [HealthProbeWorkoutRow] = []
                    for s in results ?? [] {
                        guard let w = s as? HKWorkout else { continue }
                        rows.append(HealthProbeWorkoutRow(activityRawValue: w.workoutActivityType.rawValue,
                                                          start: w.startDate,
                                                          end: w.endDate,
                                                          duration: w.duration))
                    }
                    cont.resume(returning: (rows, nil, rows.count >= cap))
                }
                store.execute(q)
            }
        }
    }

    static func enableBackgroundDelivery(_ store: HKHealthStore,
                                         type: HKObjectType,
                                         timeout: Double) async -> (Bool, String?) {
        await withProbeTimeout(timeout, fallback: (false, "timed out" as String?)) {
            await withCheckedContinuation { (cont: CheckedContinuation<(Bool, String?), Never>) in
                let gate = HealthProbeGate()
                store.enableBackgroundDelivery(for: type, frequency: .immediate) { ok, err in
                    guard gate.claim() else { return }
                    cont.resume(returning: (ok, err.map { errorText($0) }))
                }
            }
        }
    }

    static func disableBackgroundDelivery(_ store: HKHealthStore,
                                          type: HKObjectType,
                                          timeout: Double) async -> (Bool, String?) {
        await withProbeTimeout(timeout, fallback: (false, "timed out" as String?)) {
            await withCheckedContinuation { (cont: CheckedContinuation<(Bool, String?), Never>) in
                let gate = HealthProbeGate()
                store.disableBackgroundDelivery(for: type) { ok, err in
                    guard gate.claim() else { return }
                    cont.resume(returning: (ok, err.map { errorText($0) }))
                }
            }
        }
    }
}

// MARK: - Probe

struct HealthProbe: TelemetryProbe {
    let key = "health"
    let title = "HealthKit"

    /// Wall-clock budget for the ~200-type sweep. ProbeRunner replaces this
    /// WHOLE section with a one-line timeout stub at 180s, so the sweep gets a
    /// deliberately smaller slice and the clock starts only AFTER the
    /// permission sheet is dismissed — otherwise a user who reads the sheet for
    /// 40 seconds silently turns every type into "skipped".
    private let sweepBudget: Double = 105
    private let perQueryTimeout: Double = 4
    private let maxInFlight = 6

    /// ProbeRunner discards this ENTIRE section — all ~215 items — if `run()`
    /// exceeds 180s. Losing everything is far worse than losing the tail, so
    /// every phase below is gated on a single hard deadline set at entry.
    private let sectionBudget: Double = 150
    /// Slice reserved for the post-sweep phases (workouts, rings, background,
    /// clinical) so the sweep cannot starve them.
    private let tailReserve: Double = 45

    func run() async -> ProbeSection {
        let hardDeadline = Date().addingTimeInterval(sectionBudget)
        var items: [ProbeItem] = []

        /// Skip a tail phase unless at least `needs` seconds remain — starting a
        /// phase that cannot finish inside the budget is what blows past 180s.
        func outOfTime(_ key: String, _ label: String, needs: Double) -> ProbeItem? {
            guard hardDeadline.timeIntervalSinceNow < needs else { return nil }
            return ProbeItem(key, label, .error,
                             value: "skipped: section budget exhausted",
                             detail: "The \(Int(sectionBudget))s section budget ran out before this phase. It is skipped deliberately: ProbeRunner discards the whole section at 180s, so a partial report beats no report.")
        }

        guard HKHealthStore.isHealthDataAvailable() else {
            items.append(ProbeItem("health.available", "HealthKit availability", .unavailable,
                                   value: "isHealthDataAvailable() == false",
                                   detail: "No HealthKit database on this device. Nothing else in this section can run."))
            return section("HealthKit is not available on this device — the entire section is void.", items)
        }

        let box = HealthProbeStoreBox()
        let store = box.store

        items.append(ProbeItem("health.available", "HealthKit availability", .ok,
                               value: "isHealthDataAvailable() == true",
                               extra: ["simulator": ProbeEnv.isSimulator ? "true" : "false",
                                       "hardware": ProbeEnv.hardwareModel()]))

        // ---- Resolve the catalog against THIS OS -----------------------------
        var quantityTypes: [(String, HKQuantityType)] = []
        var unresolved: [String] = []
        for id in HealthProbeCatalog.quantity {
            if let t = HKQuantityType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: id)) {
                quantityTypes.append((id, t))
            } else {
                unresolved.append(id)
            }
        }
        var categoryTypes: [(String, HKCategoryType)] = []
        for id in HealthProbeCatalog.category {
            if let t = HKCategoryType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: id)) {
                categoryTypes.append((id, t))
            } else {
                unresolved.append(id)
            }
        }
        var characteristicTypes: [(String, HKCharacteristicType)] = []
        for id in HealthProbeCatalog.characteristic {
            if let t = HKObjectType.characteristicType(forIdentifier: HKCharacteristicTypeIdentifier(rawValue: id)) {
                characteristicTypes.append((id, t))
            } else {
                unresolved.append(id)
            }
        }
        var correlationTypes: [(String, HKCorrelationType)] = []
        for id in HealthProbeCatalog.correlation {
            if let t = HKObjectType.correlationType(forIdentifier: HKCorrelationTypeIdentifier(rawValue: id)) {
                correlationTypes.append((id, t))
            } else {
                unresolved.append(id)
            }
        }
        var seriesTypes: [(String, HKSeriesType)] = []
        for id in HealthProbeCatalog.series {
            // seriesType(forIdentifier:) takes a bare String, not a wrapper.
            if let t = HKObjectType.seriesType(forIdentifier: id) {
                seriesTypes.append((id, t))
            } else {
                unresolved.append(id)
            }
        }
        var documentTypes: [(String, HKDocumentType)] = []
        for id in HealthProbeCatalog.document {
            if let t = HKObjectType.documentType(forIdentifier: HKDocumentTypeIdentifier(rawValue: id)) {
                documentTypes.append((id, t))
            } else {
                unresolved.append(id)
            }
        }
        var clinicalTypes: [(String, HKClinicalType)] = []
        for id in HealthProbeCatalog.clinical {
            if let t = HKObjectType.clinicalType(forIdentifier: HKClinicalTypeIdentifier(rawValue: id)) {
                clinicalTypes.append((id, t))
            }
        }

        // One-off types that have no string identifier at all. Note the
        // workout type is deliberately NOT in this list — it gets its own
        // richer inventory below.
        var specials: [(String, String, HKSampleType)] = []   // key, label, type
        specials.append(("electrocardiogram", "Electrocardiogram (ECG)", HKObjectType.electrocardiogramType()))
        specials.append(("audiogram", "Audiogram (hearing test)", HKObjectType.audiogramSampleType()))
        specials.append(("visionPrescription", "Vision prescription", HKObjectType.visionPrescriptionType()))
        if #available(iOS 18.0, *) {
            // Mood/valence logging. High-signal and almost always missed,
            // because nothing outside the Health app surfaces it.
            specials.append(("stateOfMind", "State of Mind (mood / valence)", HKObjectType.stateOfMindType()))
            specials.append(("assessment.GAD7", "GAD-7 anxiety assessment", HKScoredAssessmentType(.GAD7)))
            specials.append(("assessment.PHQ9", "PHQ-9 depression assessment", HKScoredAssessmentType(.PHQ9)))
        }
        if #available(iOS 26.0, *) {
            specials.append(("medicationDoseEvent", "Medication dose events", HKObjectType.medicationDoseEventType()))
        }

        // HKUserAnnotatedMedicationType inherits HKObjectType, NOT HKSampleType,
        // so it can be authorized but never sample-queried. Kept separate on
        // purpose rather than force-cast.
        var nonSampleTypes: [(String, String, HKObjectType)] = []
        nonSampleTypes.append(("activitySummary", "Activity summary type", HKObjectType.activitySummaryType()))
        if #available(iOS 26.0, *) {
            nonSampleTypes.append(("userAnnotatedMedication", "User-annotated medications",
                                   HKObjectType.userAnnotatedMedicationType()))
        }

        let coreResolved = quantityTypes.count + categoryTypes.count + characteristicTypes.count
        let coreCatalogued = HealthProbeCatalog.quantity.count
            + HealthProbeCatalog.category.count
            + HealthProbeCatalog.characteristic.count

        items.append(ProbeItem("health.catalog", "Catalog resolution", .ok,
                               value: "\(coreResolved) of \(coreCatalogued) catalogued quantity/category/characteristic identifiers exist on this OS",
                               detail: unresolved.isEmpty
                                   ? "Every catalogued identifier exists on this OS."
                                   : "Not present on this OS (reported individually as .unavailable): "
                                       + unresolved.joined(separator: ", "),
                               extra: ["quantityResolved": ProbeEnv.int(quantityTypes.count),
                                       "quantityCatalogued": ProbeEnv.int(HealthProbeCatalog.quantity.count),
                                       "categoryResolved": ProbeEnv.int(categoryTypes.count),
                                       "categoryCatalogued": ProbeEnv.int(HealthProbeCatalog.category.count),
                                       "characteristicResolved": ProbeEnv.int(characteristicTypes.count),
                                       "correlationResolved": ProbeEnv.int(correlationTypes.count),
                                       "seriesResolved": ProbeEnv.int(seriesTypes.count),
                                       "documentResolved": ProbeEnv.int(documentTypes.count),
                                       "clinicalResolved": ProbeEnv.int(clinicalTypes.count),
                                       "specialTypes": ProbeEnv.int(specials.count),
                                       "unresolvedCount": ProbeEnv.int(unresolved.count)]))

        for id in unresolved {
            items.append(ProbeItem("health.unresolved.\(id)", HealthProbeCatalog.label(id), .unavailable,
                                   value: "identifier not present on this OS",
                                   detail: "\(id) is in the catalog but the failable initializer returned nil, so this OS build does not know it. Catalogued because a newer OS does."))
        }

        // ---- ONE authorization request for the whole resolved set ------------
        var readSet: Set<HKObjectType> = []
        for (_, t) in quantityTypes { readSet.insert(t) }
        for (_, t) in categoryTypes { readSet.insert(t) }
        for (_, t) in characteristicTypes { readSet.insert(t) }
        for (_, t) in correlationTypes { readSet.insert(t) }
        for (_, t) in seriesTypes { readSet.insert(t) }
        // documentTypes (HKDocumentTypeIdentifierCDA) are DELIBERATELY EXCLUDED from the
        // main request. CDA documents belong to the health-records family, so asking for
        // them without com.apple.developer.healthkit.access makes HealthKit raise rather
        // than return an error — and one bad type poisons the entire batch, costing every
        // other type in it. They are probed separately alongside clinical records, where a
        // throw costs one item instead of the whole section.
        for (_, _, t) in specials { readSet.insert(t) }
        for (_, _, t) in nonSampleTypes { readSet.insert(t) }
        readSet.insert(HKObjectType.workoutType())
        if let route = HKObjectType.seriesType(forIdentifier: "HKWorkoutRouteTypeIdentifier") {
            readSet.insert(route)
        }

        // Bounded even though it blocks on a human. If the user walks away from
        // the sheet, proceeding with unknown authorization still produces a
        // real report; blocking here produces nothing at all.
        let authStart = Date()
        let (authOK, authErr) = await withProbeTimeout(
            90.0, fallback: (false, "the permission sheet was not answered within 90s" as String?)
        ) {
            await HealthProbeHK.requestRead(store, readSet)
        }
        let authElapsed = Date().timeIntervalSince(authStart)

        items.append(ProbeItem(
            "health.authorization", "Read authorization (single request)",
            authErr == nil ? (authOK ? .ok : .partial) : .error,
            value: authErr == nil
                ? "requestAuthorization returned success=\(authOK) for \(readSet.count) types"
                : "requestAuthorization failed",
            detail: """
                HealthKit READ authorization is deliberately opaque. \
                `authorizationStatus(for:)` reports SHARE (write) status ONLY — it returns \
                .notDetermined for a read grant the user has already given, by design, so an app \
                cannot infer which metrics the user hid. The success flag below means only that the \
                sheet was presented and dismissed without error; it says nothing about what was \
                granted. RETURNED DATA IS THE ONLY PROOF OF READ ACCESS. That is why every type \
                below is judged by whether a sample actually came back, and why `.empty` is \
                genuinely ambiguous: it means either "no data" or "read denied".
                \(authErr.map { "Error: " + $0 } ?? "")
                """,
            extra: ["typesRequested": ProbeEnv.int(readSet.count),
                    "success": authOK ? "true" : "false",
                    "sheetSeconds": ProbeEnv.num(authElapsed)]))

        // HealthKit's own preferred units for this user — enrichment only. A
        // single unauthorized type can fail the whole batch, so the static map
        // stays the source of truth and this only overrides where it answered.
        let (preferred, preferredErr) = await withProbeTimeout(
            8.0, fallback: ([String: String](), "timed out" as String?)
        ) {
            await HealthProbeHK.preferredUnits(store, Set(quantityTypes.map { $0.1 }))
        }
        var preferredExtra: [String: String] = [:]
        for (id, unitString) in preferred {
            // Built by hand, not Dictionary(uniqueKeysWithValues:), which traps
            // on a duplicate key.
            preferredExtra[HealthProbeCatalog.label(id)] = unitString
        }
        items.append(ProbeItem("health.preferredUnits", "User's preferred display units",
                               preferredErr == nil ? (preferred.isEmpty ? .empty : .ok) : .partial,
                               value: "\(preferred.count) of \(quantityTypes.count) quantity types returned a preferred unit",
                               detail: preferredErr.map { "preferredUnits(for:) error: " + $0 }
                                   ?? "These are the units this user's Health app is configured for; the collector should store canonical units and render these.",
                               extra: preferredExtra.isEmpty ? nil : preferredExtra))

        // Types that can be authorized but never sample-queried.
        for (k, label, t) in nonSampleTypes {
            items.append(ProbeItem("health.objectType.\(k)", label, .partial,
                                   value: "type resolves; not an HKSampleType",
                                   detail: "Included in the authorization request, but it inherits HKObjectType rather than HKSampleType, so HKSampleQuery cannot be run against it. Where a dedicated query exists (activity summaries) it is reported separately below.",
                                   extra: ["typeIdentifier": t.identifier,
                                           "sharingAuthorization": String(describing: store.authorizationStatus(for: t))]))
        }

        // ---- Bounded sweep ---------------------------------------------------
        // Whichever comes first: the sweep's own budget, or the point at which
        // the post-sweep phases need their reserved slice.
        let deadline = min(Date().addingTimeInterval(sweepBudget),
                           hardDeadline.addingTimeInterval(-tailReserve))

        var work: [HealthProbeWork] = []
        for (id, t) in quantityTypes {
            var unit = HealthProbeUnits.byIdentifier[id]
            if let s = preferred[id] {
                // Only adopt a preferred unit we can express safely: match it
                // against an already-constructed unit rather than parsing the
                // string with HKUnit(from:), which traps on anything malformed.
                if let match = HealthProbeUnits.candidates.first(where: { $0.unitString == s }) {
                    unit = match
                }
            }
            work.append(HealthProbeWork(key: "health.q.\(id)",
                                       label: HealthProbeCatalog.label(id), type: t, unit: unit))
        }
        for (id, t) in categoryTypes {
            work.append(HealthProbeWork(key: "health.c.\(id)",
                                        label: HealthProbeCatalog.label(id), type: t, unit: nil))
        }
        for (id, t) in seriesTypes {
            work.append(HealthProbeWork(key: "health.series.\(id)",
                                        label: HealthProbeCatalog.label(id), type: t, unit: nil))
        }
        for (id, t) in documentTypes {
            work.append(HealthProbeWork(key: "health.doc.\(id)",
                                        label: HealthProbeCatalog.label(id), type: t, unit: nil))
        }
        for (k, label, t) in specials {
            work.append(HealthProbeWork(key: "health.special.\(k)", label: label, type: t, unit: nil))
        }

        // BOUNDED CONCURRENCY: `maxInFlight` HealthKit queries, never more.
        // Firing ~200 at once makes healthd throttle and the report becomes a
        // measurement of the throttle rather than of the data.
        var swept: [ProbeItem] = []
        await withTaskGroup(of: ProbeItem.self) { group in
            var next = 0
            while next < work.count && next < self.maxInFlight {
                let w = work[next]
                next += 1
                group.addTask { await self.scanSampleType(box, work: w, deadline: deadline) }
            }
            while let done = await group.next() {
                swept.append(done)
                if next < work.count {
                    let w = work[next]
                    next += 1
                    group.addTask { await self.scanSampleType(box, work: w, deadline: deadline) }
                }
            }
        }
        swept.sort { $0.key < $1.key }
        items.append(contentsOf: swept)

        // ---- Characteristics (direct reads, no query) ------------------------
        items.append(contentsOf: characteristics(store))

        // ---- Correlations ----------------------------------------------------
        for (id, t) in correlationTypes {
            let status = store.authorizationStatus(for: t)
            items.append(ProbeItem("health.corr.\(id)", HealthProbeCatalog.label(id), .partial,
                                   value: "type resolves",
                                   detail: "Correlations are containers over their member samples; the members are inventoried individually above. Not queried separately to keep the sweep bounded.",
                                   extra: ["sharingAuthorization": String(describing: status)]))
        }

        // ---- Workouts --------------------------------------------------------
        if let skip = outOfTime("health.workouts", "Workout inventory", needs: 10) {
            items.append(skip)
        } else {
            items.append(contentsOf: await workoutItems(store, hardDeadline: hardDeadline))
        }

        // ---- Activity rings --------------------------------------------------
        if let skip = outOfTime("health.activitySummary",
                                "Activity rings (move / exercise / stand)", needs: 8) {
            items.append(skip)
        } else {
            items.append(await activitySummaryItem(store, hardDeadline: hardDeadline))
        }

        // ---- Background delivery + observer ----------------------------------
        if let skip = outOfTime("health.backgroundDelivery",
                                "Background delivery (step count)", needs: 12) {
            items.append(skip)
        } else {
            items.append(contentsOf: await backgroundItems(store, hardDeadline: hardDeadline))
        }

        // ---- Clinical records ------------------------------------------------
        if let skip = outOfTime("health.clinical",
                                "Clinical records (health records)", needs: 10) {
            items.append(skip)
        } else {
            items.append(await clinicalItem(store, types: clinicalTypes, hardDeadline: hardDeadline))
        }

        // ---- Summary ---------------------------------------------------------
        var tally: [ProbeStatus: Int] = [:]
        for i in items { tally[i.status, default: 0] += 1 }
        // `.partial` still means a sample CAME BACK — only a follow-up sub-query
        // degraded — so counting only `.ok` would undercount exactly the types
        // that produced data.
        let live = items.filter {
            ($0.status == .ok || $0.status == .partial)
                && ($0.key.hasPrefix("health.q.") || $0.key.hasPrefix("health.c."))
        }
        var oldestOverall: String?
        for i in live {
            if let o = i.extra?["oldestSample"] {
                if oldestOverall == nil || o < (oldestOverall ?? "") { oldestOverall = o }
            }
        }

        let summary = """
            \(live.count) of \(quantityTypes.count + categoryTypes.count) resolved quantity/category \
            types returned real samples on this device; \(tally[.empty] ?? 0) resolved but are empty \
            and \(tally[.unavailable] ?? 0) do not exist on this OS. Oldest datum found anywhere: \
            \(oldestOverall ?? "none"). READ AUTHORIZATION IS OPAQUE BY DESIGN — \
            authorizationStatus(for:) reports SHARE status only and returns .notDetermined even for \
            granted reads, so returned data is the only proof of read access and every `.empty` \
            above is ambiguous between "no data" and "read denied". Types are resolved from raw \
            string identifiers via the failable initializers, so a catalog entry newer than this OS \
            degrades to .unavailable instead of trapping. The sweep runs at most \(maxInFlight) \
            HealthKit queries concurrently with a \(Int(perQueryTimeout))s per-query deadline and a \
            \(Int(sweepBudget))s sweep budget started AFTER the permission sheet closed, under a \
            \(Int(sectionBudget))s hard section budget — ProbeRunner discards this ENTIRE section at \
            180s, so late phases are skipped on purpose rather than risking the whole report. \
            Not probed: HKAnchoredObjectQuery/HKStatisticsCollectionQuery (delta and bucketing \
            mechanics, not inventory), HKAttachmentStore, HKVerifiableClinicalRecordQuery \
            (needs the same gated entitlement as clinical records), and CDA document CONTENT \
            (presence only) — all noted so their absence is not read as a negative finding.
            """

        return section(summary, items)
    }

    // MARK: - Per-type sweep

    private func scanSampleType(_ box: HealthProbeStoreBox,
                                work: HealthProbeWork,
                                deadline: Date) async -> ProbeItem {
        let key = work.key
        let label = work.label
        let type = work.type
        let unit = work.unit
        let store = box.store
        let shareStatus = String(describing: store.authorizationStatus(for: type))

        if Date() >= deadline {
            return ProbeItem(key, label, .error,
                             value: "skipped",
                             detail: "Sweep budget exhausted before this type was reached. Re-run; the sweep order is stable.",
                             extra: ["sharingAuthorization": shareStatus,
                                     "typeIdentifier": type.identifier])
        }

        let newest = await HealthProbeHK.firstSample(store, type: type, ascending: false,
                                                     unit: unit, timeout: perQueryTimeout)

        var extra: [String: String] = ["typeIdentifier": type.identifier,
                                       "sharingAuthorization": shareStatus]

        switch newest {
        case .timedOut:
            return ProbeItem(key, label, .error,
                             value: "query timed out after \(Int(perQueryTimeout))s",
                             detail: "HealthKit never called back for the newest-sample query.",
                             extra: extra)

        case .failed(let msg, let authError):
            return ProbeItem(key, label, authError ? .denied : .error,
                             value: authError ? "read denied" : "query failed",
                             detail: msg, extra: extra)

        case .empty:
            return ProbeItem(key, label, .empty,
                             value: "no samples",
                             detail: "The type exists and the request did not error, but zero samples came back. AMBIGUOUS: HealthKit returns an empty set for a denied read exactly as it does for a genuinely empty type — it will not tell an app which.",
                             extra: extra)

        case .sample(let newestInfo):
            extra["newestSample"] = ProbeEnv.stamp(newestInfo.start)
            extra["newestSampleEnd"] = ProbeEnv.stamp(newestInfo.end)
            extra["newestAge"] = ProbeEnv.age(newestInfo.start)
            extra["newestValue"] = newestInfo.valueText
            extra["unit"] = newestInfo.unitText
            extra["sampleClass"] = newestInfo.sampleClass
            extra["newestSourceName"] = newestInfo.sourceName
            extra["newestSourceBundle"] = newestInfo.sourceBundle
            extra["newestProductType"] = newestInfo.productType
            extra["newestSourceOSVersion"] = newestInfo.osVersion
            extra["newestDeviceModel"] = newestInfo.deviceModel
            extra["newestDeviceName"] = newestInfo.deviceName
            extra["newestDeviceManufacturer"] = newestInfo.deviceManufacturer
            extra["newestDeviceHardware"] = newestInfo.deviceHardware
            extra["newestDeviceSoftware"] = newestInfo.deviceSoftware
            if let c = newestInfo.coalescedCount { extra["coalescedSampleCount"] = ProbeEnv.int(c) }
            if !newestInfo.metadataKeys.isEmpty {
                extra["metadataKeys"] = newestInfo.metadataKeys.joined(separator: ", ")
            }
            for (k, v) in newestInfo.notes { extra[k] = v }

            var degraded = false

            // The single highest-value unknown: how far back does HealthKit
            // actually hand data over on a first authorization?
            let oldest = await HealthProbeHK.firstSample(store, type: type, ascending: true,
                                                         unit: unit, timeout: perQueryTimeout)
            switch oldest {
            case .sample(let o):
                extra["oldestSample"] = ProbeEnv.stamp(o.start)
                extra["oldestAge"] = ProbeEnv.age(o.start)
                extra["oldestValue"] = o.valueText
                extra["oldestSourceName"] = o.sourceName
                extra["oldestProductType"] = o.productType
                let span = newestInfo.start.timeIntervalSince(o.start) / 86_400
                extra["historyDays"] = ProbeEnv.num(max(0, span))
                extra["historyYears"] = ProbeEnv.num(max(0, span / 365.25))
            case .empty:
                extra["oldestSample"] = "none returned (raced with newest)"
                degraded = true
            case .failed(let m, _):
                extra["oldestSampleError"] = m
                degraded = true
            case .timedOut:
                extra["oldestSampleError"] = "timed out after \(Int(perQueryTimeout))s"
                degraded = true
            }

            switch await HealthProbeHK.recentCount(store, type: type, days: 7, cap: 1000,
                                                   timeout: perQueryTimeout) {
            case .counted(let n, let capped):
                extra["recent7dSampleCount"] = capped ? "\(ProbeEnv.int(n))+ (capped)" : ProbeEnv.int(n)
                if !capped, n > 0 {
                    extra["recent7dSamplesPerDay"] = ProbeEnv.num(Double(n) / 7.0)
                }
            case .failed(let m):
                extra["recent7dSampleCountError"] = m
                degraded = true
            case .timedOut:
                extra["recent7dSampleCountError"] = "timed out"
                degraded = true
            }

            let (srcNames, srcErr) = await HealthProbeHK.sources(store, type: type,
                                                                 timeout: perQueryTimeout)
            if let srcErr {
                extra["sourcesError"] = srcErr
                degraded = true
            } else {
                extra["sourceCount"] = ProbeEnv.int(srcNames.count)
                extra["sources"] = srcNames.joined(separator: " | ")
            }

            let value = [newestInfo.valueText, ProbeEnv.age(newestInfo.start)]
                .compactMap { $0 }
                .joined(separator: " · ")

            return ProbeItem(key, label, degraded ? .partial : .ok,
                             value: value.isEmpty ? "sample present" : value,
                             detail: "History \(extra["historyDays"] ?? "?") days · sources: \(extra["sources"] ?? "?")",
                             extra: extra)
        }
    }

    // MARK: - Characteristics

    private func characteristics(_ store: HKHealthStore) -> [ProbeItem] {
        var out: [ProbeItem] = []

        func emit(_ id: String, _ label: String, _ body: () throws -> String?) {
            let key = "health.char.\(id)"
            do {
                if let v = try body() {
                    out.append(ProbeItem(key, label, .ok, value: v,
                                         extra: ["typeIdentifier": id]))
                } else {
                    out.append(ProbeItem(key, label, .empty,
                                         value: "not set in the Health app",
                                         extra: ["typeIdentifier": id]))
                }
            } catch {
                let denied = HealthProbeHK.isAuthError(error)
                out.append(ProbeItem(key, label, denied ? .denied : .error,
                                     value: denied ? "read denied" : "read failed",
                                     detail: HealthProbeHK.errorText(error),
                                     extra: ["typeIdentifier": id]))
            }
        }

        emit("HKCharacteristicTypeIdentifierDateOfBirth", "Date of birth") {
            let comps = try store.dateOfBirthComponents()
            guard let y = comps.year else { return nil }
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone.current
            var text = "\(y)"
            if let m = comps.month, let d = comps.day {
                text = String(format: "%04d-%02d-%02d", y, m, d)
            }
            if let dob = cal.date(from: comps) {
                let years = Date().timeIntervalSince(dob) / (365.25 * 86_400)
                text += " (age \(ProbeEnv.num(years)))"
            }
            return text
        }
        emit("HKCharacteristicTypeIdentifierBiologicalSex", "Biological sex") {
            let v = try store.biologicalSex().biologicalSex
            return v == .notSet ? nil : String(describing: v)
        }
        emit("HKCharacteristicTypeIdentifierBloodType", "Blood type") {
            let v = try store.bloodType().bloodType
            return v == .notSet ? nil : String(describing: v)
        }
        emit("HKCharacteristicTypeIdentifierFitzpatrickSkinType", "Fitzpatrick skin type") {
            let v = try store.fitzpatrickSkinType().skinType
            return v == .notSet ? nil : String(describing: v)
        }
        emit("HKCharacteristicTypeIdentifierWheelchairUse", "Wheelchair use") {
            let v = try store.wheelchairUse().wheelchairUse
            return v == .notSet ? nil : String(describing: v)
        }
        emit("HKCharacteristicTypeIdentifierActivityMoveMode", "Activity move mode") {
            // iOS 14+; the deployment target is 17.0, so no guard is needed.
            let v = try store.activityMoveMode().activityMoveMode
            return String(describing: v)
        }

        return out
    }

    // MARK: - Workouts

    private func workoutItems(_ store: HKHealthStore, hardDeadline: Date) async -> [ProbeItem] {
        var out: [ProbeItem] = []
        let cap = 10_000
        let budget = max(4.0, min(25.0, hardDeadline.timeIntervalSinceNow - 30))
        let (rows, err, capped) = await HealthProbeHK.workouts(store, cap: cap, timeout: budget)

        if let err {
            out.append(ProbeItem("health.workouts", "Workout inventory", .error,
                                 value: "query failed", detail: err))
            return out
        }
        guard let firstRow = rows.first else {
            out.append(ProbeItem("health.workouts", "Workout inventory", .empty,
                                 value: "0 workouts",
                                 detail: "No HKWorkout samples returned. Ambiguous between empty and read-denied."))
            out.append(contentsOf: await workoutRouteItems(store, hardDeadline: hardDeadline))
            return out
        }
        do {
            var counts: [UInt: Int] = [:]
            var oldest = firstRow.start
            var newest = firstRow.start
            var totalSeconds: Double = 0
            for r in rows {
                counts[r.activityRawValue, default: 0] += 1
                if r.start < oldest { oldest = r.start }
                if r.start > newest { newest = r.start }
                totalSeconds += r.duration
            }
            // Written out longhand on purpose: the fluent map/sorted/map/joined
            // chain over a tuple of (String, Int) blows the Swift type checker's
            // time budget and fails to compile.
            var namedCounts: [(name: String, count: Int)] = []
            for (raw, n) in counts {
                let nm = HealthProbeWorkoutNames.byRawValue[raw] ?? "activityType(\(raw))"
                namedCounts.append((name: nm, count: n))
            }
            namedCounts.sort { a, b in
                if a.count == b.count { return a.name < b.name }
                return a.count > b.count
            }
            var breakdownParts: [String] = []
            for pair in namedCounts {
                breakdownParts.append("\(pair.name)=\(pair.count)")
            }
            let breakdown = breakdownParts.joined(separator: ", ")

            var extra: [String: String] = [
                "workoutCount": capped ? "\(ProbeEnv.int(rows.count))+ (capped at \(ProbeEnv.int(cap)))"
                                       : ProbeEnv.int(rows.count),
                "distinctActivityTypes": ProbeEnv.int(counts.count),
                "activityTypeBreakdown": breakdown,
                "totalHours": ProbeEnv.num(totalSeconds / 3600)
            ]
            extra["oldestWorkout"] = ProbeEnv.stamp(oldest)
            extra["oldestWorkoutAge"] = ProbeEnv.age(oldest)
            extra["newestWorkout"] = ProbeEnv.stamp(newest)
            extra["newestWorkoutAge"] = ProbeEnv.age(newest)
            extra["historyDays"] = ProbeEnv.num(newest.timeIntervalSince(oldest) / 86_400)

            out.append(ProbeItem("health.workouts", "Workout inventory", .ok,
                                 value: "\(ProbeEnv.int(rows.count)) workouts across \(counts.count) activity types",
                                 detail: breakdown,
                                 extra: extra))
        }

        out.append(contentsOf: await workoutRouteItems(store, hardDeadline: hardDeadline))
        return out
    }

    private func workoutRouteItems(_ store: HKHealthStore, hardDeadline: Date) async -> [ProbeItem] {
        var out: [ProbeItem] = []
        let remaining = hardDeadline.timeIntervalSinceNow
        guard remaining > 6 else {
            out.append(ProbeItem("health.workoutRoutes", "Workout routes (GPS)", .error,
                                 value: "skipped: section budget exhausted"))
            return out
        }
        // Routes are a separate series type; presence decides whether GPS
        // tracks are recoverable from Health at all.
        if let routeType = HKObjectType.seriesType(forIdentifier: "HKWorkoutRouteTypeIdentifier") {
            switch await HealthProbeHK.firstSample(store, type: routeType, ascending: false,
                                                   unit: nil, timeout: min(8, remaining - 2)) {
            case .sample(let info):
                var extra: [String: String] = [:]
                extra["newestRoute"] = ProbeEnv.stamp(info.start)
                extra["newestRouteAge"] = ProbeEnv.age(info.start)
                extra["sourceName"] = info.sourceName
                extra["productType"] = info.productType
                switch await HealthProbeHK.recentCount(
                    store, type: routeType, days: 3650, cap: 5000,
                    timeout: max(2, min(12, hardDeadline.timeIntervalSinceNow - 20))) {
                case .counted(let n, let capped):
                    extra["routeCount10y"] = capped ? "\(ProbeEnv.int(n))+ (capped)" : ProbeEnv.int(n)
                default:
                    break
                }
                out.append(ProbeItem("health.workoutRoutes", "Workout routes (GPS)", .ok,
                                     value: "routes present",
                                     detail: "HKWorkoutRoute samples exist; per-route CLLocation tracks are readable with HKWorkoutRouteQuery.",
                                     extra: extra))
            case .empty:
                out.append(ProbeItem("health.workoutRoutes", "Workout routes (GPS)", .empty,
                                     value: "no routes",
                                     detail: "No HKWorkoutRoute samples. Either no outdoor workouts were recorded with GPS, or the read was denied."))
            case .failed(let m, let auth):
                out.append(ProbeItem("health.workoutRoutes", "Workout routes (GPS)",
                                     auth ? .denied : .error, value: "query failed", detail: m))
            case .timedOut:
                out.append(ProbeItem("health.workoutRoutes", "Workout routes (GPS)", .error,
                                     value: "timed out"))
            }
        } else {
            out.append(ProbeItem("health.workoutRoutes", "Workout routes (GPS)", .unavailable,
                                 value: "HKWorkoutRouteTypeIdentifier does not resolve on this OS"))
        }

        return out
    }

    // MARK: - Activity rings

    private func activitySummaryItem(_ store: HKHealthStore, hardDeadline: Date) async -> ProbeItem {
        let budget = max(3.0, min(15.0, hardDeadline.timeIntervalSinceNow - 4))
        let (rows, err) = await HealthProbeHK.activitySummaries(store, days: 30, timeout: budget)
        if let err {
            return ProbeItem("health.activitySummary", "Activity rings (move / exercise / stand)",
                             .error, value: "query failed", detail: err)
        }
        guard !rows.isEmpty else {
            return ProbeItem("health.activitySummary", "Activity rings (move / exercise / stand)",
                             .empty, value: "no summaries in the last 30 days",
                             detail: "HKActivitySummaryQuery returned nothing. Activity rings normally require a paired Apple Watch (or Move-mode tracking on iPhone).")
        }
        var extra: [String: String] = ["daysReturned": ProbeEnv.int(rows.count)]
        var moveTotal = 0.0
        var moveDays = 0
        for (i, r) in rows.enumerated() {
            if let d = r["date"] { extra["day\(i).date"] = d }
            for k in ["activeEnergyKcal", "moveGoalKcal", "exerciseMin", "exerciseGoalMin",
                      "standHours", "standGoalHours"] {
                if let v = r[k] { extra["day\(i).\(k)"] = v }
            }
            if let v = r["activeEnergyKcal"],
               let d = Double(v.replacingOccurrences(of: ",", with: "")) {
                moveTotal += d
                moveDays += 1
            }
        }
        if moveDays > 0 {
            extra["avgActiveEnergyKcalPerDay"] = ProbeEnv.num(moveTotal / Double(moveDays))
        }
        return ProbeItem("health.activitySummary", "Activity rings (move / exercise / stand)",
                         .ok,
                         value: "\(rows.count) daily summaries in the last 30 days",
                         detail: "Ring goals and closures are queryable per day; a collector can backfill them without touching individual samples.",
                         extra: extra)
    }

    // MARK: - Background delivery + observer

    private func backgroundItems(_ store: HKHealthStore, hardDeadline: Date) async -> [ProbeItem] {
        var out: [ProbeItem] = []
        guard let steps = HKQuantityType.quantityType(
            forIdentifier: HKQuantityTypeIdentifier(rawValue: "HKQuantityTypeIdentifierStepCount")) else {
            out.append(ProbeItem("health.backgroundDelivery", "Background delivery (step count)",
                                 .unavailable, value: "step count type does not resolve"))
            return out
        }

        // THE signal for whether unattended collection is possible at this
        // signing tier: enableBackgroundDelivery needs
        // com.apple.developer.healthkit.background-delivery, which a free /
        // personal-team profile does not carry.
        let (enabled, enableErr) = await HealthProbeHK.enableBackgroundDelivery(
            store, type: steps,
            timeout: max(3.0, min(12.0, hardDeadline.timeIntervalSinceNow - 7)))

        var extra: [String: String] = ["type": "HKQuantityTypeIdentifierStepCount",
                                       "frequency": "immediate"]
        if let enableErr { extra["error"] = enableErr }

        if enabled && enableErr == nil {
            out.append(ProbeItem("health.backgroundDelivery", "Background delivery (step count)",
                                 .ok,
                                 value: "enableBackgroundDelivery succeeded",
                                 detail: "The com.apple.developer.healthkit.background-delivery entitlement IS present at this signing tier. Continuous unattended health collection is possible: HKObserverQuery will wake the app on new samples. Left ENABLED deliberately so a follow-up build can observe real wake behaviour; call disableBackgroundDelivery to undo.",
                                 extra: extra))
        } else {
            out.append(ProbeItem("health.backgroundDelivery", "Background delivery (step count)",
                                 .denied,
                                 value: "enableBackgroundDelivery failed",
                                 detail: "Background health delivery is NOT available at this signing tier — the collector must poll from the foreground or from a BGAppRefresh task instead of being woken by HealthKit. Error: \(enableErr ?? "returned false with no error")",
                                 extra: extra))
            // Nothing was enabled, so there is deliberately nothing to undo —
            // disableBackgroundDelivery is NOT called here.
        }

        // Observer query: does the handler wire up at all? It only fires on
        // CHANGE, so silence within the window is an expected outcome, not a
        // failure — reported as such rather than as an error.
        let flag = HealthProbeFlag()
        let gate = HealthProbeGate()
        let observer = HKObserverQuery(sampleType: steps, predicate: nil) { _, completion, _ in
            // HealthKit REQUIRES this completion handler be invoked, or it
            // escalates and eventually stops delivering.
            completion()
            if gate.claim() { flag.set() }
        }
        store.execute(observer)
        let observeWindow = max(1.0, min(6.0, hardDeadline.timeIntervalSinceNow - 1))
        var waited = 0.0
        while waited < observeWindow && !flag.value {
            try? await Task.sleep(nanoseconds: 250_000_000)
            waited += 0.25
        }
        let fired = flag.value
        store.stop(observer)

        out.append(ProbeItem("health.observerQuery", "HKObserverQuery (step count)",
                             fired ? .ok : .partial,
                             value: fired ? "handler fired within \(ProbeEnv.num(waited))s"
                                          : "no update within \(ProbeEnv.num(observeWindow))s",
                             detail: fired
                                 ? "The observer delivered an update and its completion handler was invoked. Query stopped afterwards so it does not run for the app's lifetime."
                                 : "Registered without error but nothing changed during the window. HKObserverQuery only fires on new/changed samples, so silence here is expected and does NOT indicate failure. Query stopped afterwards.",
                             extra: ["waitedSeconds": ProbeEnv.num(waited),
                                     "stoppedAfterProbe": "true"]))

        return out
    }

    // MARK: - Clinical records

    private func clinicalItem(_ store: HKHealthStore,
                              types: [(String, HKClinicalType)],
                              hardDeadline: Date) async -> ProbeItem {
        guard !types.isEmpty else {
            return ProbeItem("health.clinical", "Clinical records (health records)", .unavailable,
                             value: "no clinical type identifiers resolve on this OS")
        }
        let set = Set(types.map { $0.1 as HKObjectType })
        let authBudget = max(3.0, min(30.0, hardDeadline.timeIntervalSinceNow - 12))
        let (ok, err) = await withProbeTimeout(authBudget, fallback: (false, "timed out" as String?)) {
            await HealthProbeHK.requestRead(store, set)
        }

        var extra: [String: String] = ["typesRequested": ProbeEnv.int(set.count),
                                       "identifiers": types.map { $0.0 }.joined(separator: ", ")]
        if let err { extra["error"] = err }

        guard err == nil, ok else {
            return ProbeItem("health.clinical", "Clinical records (health records)", .denied,
                             value: "authorization request rejected",
                             detail: "Clinical record types require the com.apple.developer.healthkit.access entitlement, which Apple grants per-app and which a sideloaded build does not carry. Error: \(err ?? "requestAuthorization returned false")",
                             extra: extra)
        }

        // Authorization did not error — try to actually read one.
        var reachable = 0
        var withData = 0
        for (id, t) in types {
            guard hardDeadline.timeIntervalSinceNow > 5 else {
                extra["\(HealthProbeCatalog.label(id))"] = "skipped: section budget exhausted"
                continue
            }
            switch await HealthProbeHK.firstSample(store, type: t, ascending: false,
                                                   unit: nil, timeout: 4) {
            case .sample(let info):
                reachable += 1
                withData += 1
                extra["\(HealthProbeCatalog.label(id)).newest"] = ProbeEnv.stamp(info.start)
                extra["\(HealthProbeCatalog.label(id)).source"] = info.sourceName
            case .empty:
                reachable += 1
                extra[HealthProbeCatalog.label(id)] = "reachable, empty"
            case .failed(let m, _):
                extra[HealthProbeCatalog.label(id)] = "error: \(m)"
            case .timedOut:
                extra[HealthProbeCatalog.label(id)] = "timed out"
            }
        }
        extra["reachableTypes"] = ProbeEnv.int(reachable)
        extra["typesWithData"] = ProbeEnv.int(withData)

        return ProbeItem("health.clinical", "Clinical records (health records)",
                         withData > 0 ? .ok : (reachable > 0 ? .empty : .denied),
                         value: "\(withData) of \(types.count) clinical record types returned data",
                         detail: "The clinical-record authorization request did NOT error, which means the com.apple.developer.healthkit.access entitlement is present or the request was silently accepted. Note that clinical records also require the user to have connected a healthcare provider in the Health app.",
                         extra: extra)
    }
}
