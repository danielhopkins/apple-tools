// The file format the Mac plugin reads, version 1.
//
// 🛑 ONE FORMAT, DEFINED ON THE MAC SIDE. `plugins/health/apple-plugin-health`
// parses this; its METRICS table names the labels and the canonical unit of
// each one, and this file writes exactly those labels and units so nothing
// is converted twice. Change the two together, and bump FORMAT_VERSION on
// both when a row changes shape.
//
//   apple-tools health 1
//   generated  <when>
//   window     <days>
//   source     app
//   day     <label>  <start>  <end>  <value>  <unit>
//   sample  Sleep    <start>  <end>  <stage>  count
//   workout <type>   <start>  <end>  <seconds>  <metres>  <kcal>  <avg bpm>  <source>  <lat>  <lon>
//   raw     <HK identifier>  <start>  <end>  <value>  <unit>  <source>
//   clinical <HK clinical type>  <date>  <display name>  <FHIR resource type>  <FHIR id>  <FHIR JSON, one line>
//
// Fields are tab-separated. Dates are `yyyy-MM-dd HH:mm:ss Z` in the
// phone's zone, the same shape Health's own export.xml uses. A missing
// number is an empty field.

import Foundation
import HealthKit

enum Format {
    static let version = "1"

    /// The date shape the plugin parses with one `strptime`.
    static let dates: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f
    }()

    /// `2026-09-17`, for file names.
    static let days: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func number(_ value: Double?) -> String {
        guard let value = value else { return "" }
        // ⚠️ Never the locale: the plugin strips commas but expects a dot.
        return String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value)
            .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }

    static func header(window: Int, generated: Date = Date()) -> String {
        "apple-tools health \(version)\ngenerated\t\(dates.string(from: generated))\nwindow\t\(window)\nsource\tapp\n"
    }

    static func day(label: String, start: Date, end: Date, value: Double, unit: String) -> String {
        "day\t\(label)\t\(dates.string(from: start))\t\(dates.string(from: end))\t\(number(value))\t\(unit)\n"
    }

    static func sample(label: String, start: Date, end: Date, value: String, unit: String) -> String {
        "sample\t\(label)\t\(dates.string(from: start))\t\(dates.string(from: end))\t\(value)\t\(unit)\n"
    }

    static func workout(type: String, start: Date, end: Date, seconds: Double, metres: Double?,
                        kcal: Double?, bpm: Double?, source: String, lat: Double?, lon: Double?) -> String {
        let clean = source.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
        return "workout\t\(type)\t\(dates.string(from: start))\t\(dates.string(from: end))\t"
            + "\(number(seconds))\t\(number(metres))\t\(number(kcal))\t\(number(bpm))\t\(clean)\t"
            + "\(number(lat))\t\(number(lon))\n"
    }

    static func raw(type: String, start: Date, end: Date, value: Double, unit: String, source: String) -> String {
        let clean = source.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
        return "raw\t\(type)\t\(dates.string(from: start))\t\(dates.string(from: end))\t\(number(value))\t\(unit)\t\(clean)\n"
    }

    static func clinical(type: String, date: Date, name: String, resourceType: String, id: String, json: String) -> String {
        let cleanName = name.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
        // The JSON is already one line: JSONSerialization without .prettyPrinted
        // emits none, and any newline inside a string is escaped as \n.
        return "clinical\t\(type)\t\(dates.string(from: date))\t\(cleanName)\t\(resourceType)\t\(id)\t\(json)\n"
    }
}

/// A raw sample type: every reading, not a daily figure. ⚠️ Heart rate is
/// the big one — a Watch writes one every few minutes, tens of thousands a
/// year — and it is what "how does my HRV look" and "resting heart rate
/// over the year" need. The unit written is the plugin's canonical one.
struct RawType {
    let type: HKQuantityTypeIdentifier
    let unit: HKUnit
    let unitText: String

    static let bpm = HKUnit.count().unitDivided(by: .minute())
    static let all: [RawType] = [
        RawType(type: .heartRate, unit: bpm, unitText: "count/min"),
        RawType(type: .restingHeartRate, unit: bpm, unitText: "count/min"),
        RawType(type: .walkingHeartRateAverage, unit: bpm, unitText: "count/min"),
        RawType(type: .heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), unitText: "ms"),
        RawType(type: .heartRateRecoveryOneMinute, unit: bpm, unitText: "count/min"),
        RawType(type: .oxygenSaturation, unit: .percent(), unitText: "%"),
        RawType(type: .respiratoryRate, unit: bpm, unitText: "count/min"),
        RawType(type: .bloodPressureSystolic, unit: .millimeterOfMercury(), unitText: "mmHg"),
        RawType(type: .bloodPressureDiastolic, unit: .millimeterOfMercury(), unitText: "mmHg"),
        RawType(type: .bodyMass, unit: .gramUnit(with: .kilo), unitText: "kg"),
        RawType(type: .bodyFatPercentage, unit: .percent(), unitText: "%"),
        RawType(type: .bodyMassIndex, unit: .count(), unitText: "count"),
        RawType(type: .leanBodyMass, unit: .gramUnit(with: .kilo), unitText: "kg"),
        RawType(type: .bloodGlucose, unit: HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci)), unitText: "mg/dL"),
        RawType(type: .bodyTemperature, unit: .degreeCelsius(), unitText: "degC"),
        RawType(type: .appleSleepingWristTemperature, unit: .degreeCelsius(), unitText: "degC"),
        RawType(type: .vo2Max, unit: HKUnit.literUnit(with: .milli).unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute())), unitText: "mL/min·kg"),
        RawType(type: .appleWalkingSteadiness, unit: .percent(), unitText: "%"),
        RawType(type: .environmentalAudioExposure, unit: .decibelAWeightedSoundPressureLevel(), unitText: "dBASPL"),
        RawType(type: .headphoneAudioExposure, unit: .decibelAWeightedSoundPressureLevel(), unitText: "dBASPL"),
        RawType(type: .timeInDaylight, unit: .minute(), unitText: "min"),
    ]
}

/// The clinical record types Health can hold, when a provider is connected.
let clinicalTypes: [HKClinicalTypeIdentifier] = [
    .labResultRecord, .immunizationRecord, .medicationRecord, .conditionRecord,
    .allergyRecord, .procedureRecord, .vitalSignRecord, .coverageRecord,
]

/// One daily metric: the plugin's label, the HealthKit type, how a day is
/// made, and the unit written. ⚠️ Labels and units are the plugin's, verbatim.
struct Metric {
    enum Rule { case sum, mean, last }
    let label: String
    let type: HKQuantityTypeIdentifier
    let rule: Rule
    let unit: HKUnit
    let unitText: String

    static let all: [Metric] = [
        Metric(label: "Steps", type: .stepCount, rule: .sum, unit: .count(), unitText: "count"),
        Metric(label: "Walking + Running Distance", type: .distanceWalkingRunning, rule: .sum, unit: .meter(), unitText: "m"),
        Metric(label: "Cycling Distance", type: .distanceCycling, rule: .sum, unit: .meter(), unitText: "m"),
        Metric(label: "Swimming Distance", type: .distanceSwimming, rule: .sum, unit: .meter(), unitText: "m"),
        Metric(label: "Active Calories", type: .activeEnergyBurned, rule: .sum, unit: .kilocalorie(), unitText: "kcal"),
        Metric(label: "Exercise Time", type: .appleExerciseTime, rule: .sum, unit: .minute(), unitText: "min"),
        Metric(label: "Stand Time", type: .appleStandTime, rule: .sum, unit: .minute(), unitText: "min"),
        Metric(label: "Flights Climbed", type: .flightsClimbed, rule: .sum, unit: .count(), unitText: "count"),
        Metric(label: "Resting Heart Rate", type: .restingHeartRate, rule: .mean, unit: HKUnit.count().unitDivided(by: .minute()), unitText: "count/min"),
        Metric(label: "Heart Rate Variability", type: .heartRateVariabilitySDNN, rule: .mean, unit: .secondUnit(with: .milli), unitText: "ms"),
        Metric(label: "Walking Heart Rate Average", type: .walkingHeartRateAverage, rule: .mean, unit: HKUnit.count().unitDivided(by: .minute()), unitText: "count/min"),
        Metric(label: "Oxygen Saturation", type: .oxygenSaturation, rule: .mean, unit: .percent(), unitText: "%"),
        Metric(label: "VO2 Max", type: .vo2Max, rule: .mean,
               unit: HKUnit.literUnit(with: .milli).unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute())),
               unitText: "mL/min·kg"),
        Metric(label: "Weight", type: .bodyMass, rule: .last, unit: .gramUnit(with: .kilo), unitText: "kg"),
    ]
}

/// The sleep stage names the plugin's SLEEP_STAGES table knows.
func sleepStage(_ value: Int) -> String? {
    switch HKCategoryValueSleepAnalysis(rawValue: value) {
    case .inBed: return "In Bed"
    case .asleepUnspecified: return "Asleep Unspecified"
    case .awake: return "Awake"
    case .asleepCore: return "Asleep Core"
    case .asleepDeep: return "Asleep Deep"
    case .asleepREM: return "Asleep REM"
    default: return nil
    }
}

/// The Health app's own name for a workout type, so the plugin's labels
/// and the phone's agree. Anything not listed gets the enum's name.
func workoutLabel(_ type: HKWorkoutActivityType) -> String {
    switch type {
    case .cycling: return "Cycling"
    case .running: return "Running"
    case .walking: return "Walking"
    case .hiking: return "Hiking"
    case .swimming: return "Swimming"
    case .yoga: return "Yoga"
    case .functionalStrengthTraining: return "Functional Strength Training"
    case .traditionalStrengthTraining: return "Traditional Strength Training"
    case .highIntensityIntervalTraining: return "HIIT"
    case .downhillSkiing: return "Downhill Skiing"
    case .snowboarding: return "Snowboarding"
    case .elliptical: return "Elliptical"
    case .rowing: return "Rowing"
    case .coreTraining: return "Core Training"
    case .cooldown: return "Cooldown"
    case .flexibility: return "Flexibility"
    case .mixedCardio: return "Mixed Cardio"
    case .stairClimbing: return "Stair Climbing"
    case .tennis: return "Tennis"
    case .pickleball: return "Pickleball"
    case .soccer: return "Soccer"
    case .basketball: return "Basketball"
    case .golf: return "Golf"
    case .paddleSports: return "Paddle Sports"
    case .crossCountrySkiing: return "Cross Country Skiing"
    case .other: return "Other"
    default: return "Workout \(type.rawValue)"
    }
}
