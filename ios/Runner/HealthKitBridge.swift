import Flutter
import HealthKit
import UIKit

final class HealthKitBridge: NSObject {
  static let channelName = "com.gemma_flares/health_bridge"

  private let healthStore = HKHealthStore()
  private let formatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    let instance = HealthKitBridge()
    channel.setMethodCallHandler(instance.handle)
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getAuthorizationStatus":
      getAuthorizationStatus(call: call, result: result)
    case "requestAuthorization":
      requestAuthorization(call: call, result: result)
    case "fetchSamples":
      fetchSamples(call: call, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func getAuthorizationStatus(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let arguments = call.arguments as? [String: Any],
      let rawTypes = arguments["requestedTypes"] as? [String]
    else {
      result(FlutterError(code: "invalid_arguments", message: "requestedTypes is required", details: nil))
      return
    }

    guard HKHealthStore.isHealthDataAvailable() else {
      result([
        "healthDataAvailable": false,
        "typeStatuses": Dictionary(uniqueKeysWithValues: rawTypes.map { ($0, "unavailable") }),
        "requestedAt": formatter.string(from: Date()),
      ])
      return
    }

    let typePairs = rawTypes.compactMap { rawType -> (String, HKObjectType)? in
      guard let objectType = Self.objectType(for: rawType) else { return nil }
      return (rawType, objectType)
    }
    let requestedTypes = Set(typePairs.map { $0.1 })
    healthStore.getRequestStatusForAuthorization(toShare: [], read: requestedTypes) { [formatter] status, error in
      DispatchQueue.main.async {
        if let error {
          result(FlutterError(code: "healthkit_status_failed", message: error.localizedDescription, details: nil))
          return
        }

        let mappedStatus: String
        switch status {
        case .shouldRequest:
          mappedStatus = "notDetermined"
        case .unnecessary:
          // .unnecessary means HealthKit determined the authorization sheet is
          // not required — all requested read types have already been through the
          // authorization flow. This is the closest signal HealthKit exposes for
          // read-type authorization; map it to authorized so the app correctly
          // reflects access state. (Regression: fb36008 incorrectly mapped this
          // to "denied", causing Settings to show "0 Health types authorized".)
          mappedStatus = "authorized"
        case .unknown:
          mappedStatus = "notDetermined"
        @unknown default:
          mappedStatus = "notDetermined"
        }

        let supportedTypeNames = Set(typePairs.map { $0.0 })
        let statuses = Dictionary(uniqueKeysWithValues: rawTypes.map {
          ($0, supportedTypeNames.contains($0) ? mappedStatus : "unavailable")
        })

        result([
          "healthDataAvailable": true,
          "typeStatuses": statuses,
          "requestedAt": formatter.string(from: Date()),
        ])
      }
    }
  }

  private func requestAuthorization(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let arguments = call.arguments as? [String: Any],
      let rawTypes = arguments["readTypes"] as? [String]
    else {
      result(FlutterError(code: "invalid_arguments", message: "readTypes is required", details: nil))
      return
    }

    guard HKHealthStore.isHealthDataAvailable() else {
      result([
        "status": "unavailable",
        "grantedTypes": [],
        "notGrantedTypes": rawTypes,
        "requestedAt": formatter.string(from: Date()),
      ])
      return
    }

    let typePairs = rawTypes.compactMap { rawType -> (String, HKObjectType)? in
      guard let objectType = Self.objectType(for: rawType) else { return nil }
      return (rawType, objectType)
    }
    let readTypes = Set(typePairs.map { $0.1 })
    healthStore.requestAuthorization(toShare: [], read: readTypes) { [formatter] success, error in
      DispatchQueue.main.async {
        if let error {
          result(FlutterError(code: "healthkit_request_failed", message: error.localizedDescription, details: nil))
          return
        }

        let supportedTypes = typePairs.map { $0.0 }
        let unsupportedTypes = rawTypes.filter { rawType in
          !supportedTypes.contains(rawType)
        }

        result([
          "status": success ? "success" : "failed",
          // success = true means the authorization sheet completed (or was already
          // authorized). HealthKit cannot expose per-type read grant state, so we
          // return all supported types as grantedTypes — this is the pragmatic
          // contract downstream code (Settings count, hasAuthorizedHealthAccess)
          // depends on. (Regression: fb36008 changed this to always return [],
          // causing the settings screen to show "0 Health types authorized".)
          "grantedTypes": success ? supportedTypes : [] as [String],
          "notGrantedTypes": success ? unsupportedTypes : rawTypes,
          "requestedAt": formatter.string(from: Date()),
        ])
      }
    }
  }

  private func fetchSamples(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let arguments = call.arguments as? [String: Any],
      let metricType = arguments["metricType"] as? String,
      let startTime = arguments["startTime"] as? String,
      let endTime = arguments["endTime"] as? String,
      let startDate = formatter.date(from: startTime),
      let endDate = formatter.date(from: endTime)
    else {
      result(
        FlutterError(
          code: "invalid_arguments",
          message: "metricType, startTime, and endTime are required",
          details: nil
        )
      )
      return
    }

    guard let objectType = Self.objectType(for: metricType) else {
      result([
        "status": "unavailable",
        "metricType": metricType,
        "samples": [],
        "nextPageToken": NSNull(),
        "sampleCount": 0,
      ])
      return
    }

    let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: [])
    let sortDescriptors = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
    let query = HKSampleQuery(
      sampleType: objectType,
      predicate: predicate,
      limit: HKObjectQueryNoLimit,
      sortDescriptors: sortDescriptors
    ) { [weak self] _, samples, error in
      DispatchQueue.main.async {
        if let error {
          result(FlutterError(code: "healthkit_fetch_failed", message: error.localizedDescription, details: nil))
          return
        }

        let mappedSamples = (samples ?? []).compactMap { sample in
          self?.mapSample(sample: sample, metricType: metricType)
        }

        result([
          "status": "success",
          "metricType": metricType,
          "samples": mappedSamples,
          "nextPageToken": NSNull(),
          "sampleCount": mappedSamples.count,
        ])
      }
    }

    healthStore.execute(query)
  }

  private func mapSample(sample: HKSample, metricType: String) -> [String: Any]? {
    let timezone = (sample.metadata?[HKMetadataKeyTimeZone] as? TimeZone)?.identifier
      ?? TimeZone.current.identifier

    if let workout = sample as? HKWorkout {
      var metadata: [String: Any] = [
        "workoutActivityType": workout.workoutActivityType.rawValue,
        "durationSeconds": workout.duration,
      ]
      if let energy = workout.totalEnergyBurned {
        metadata["totalEnergyKcal"] = energy.doubleValue(for: HKUnit.kilocalorie())
      }
      if let distance = workout.totalDistance {
        metadata["totalDistanceMeters"] = distance.doubleValue(for: HKUnit.meter())
      }
      return [
        "vendorSampleId": sample.uuid.uuidString,
        "sourceName": sample.sourceRevision.source.name,
        "sourceDevice": sample.device?.name ?? sample.sourceRevision.productType ?? "unknown",
        "metricType": metricType,
        "value": workout.duration / 60.0,
        "unit": "min",
        "startTime": formatter.string(from: sample.startDate),
        "endTime": formatter.string(from: sample.endDate),
        "timezone": timezone,
        "metadata": metadata,
      ]
    }

    if let quantitySample = sample as? HKQuantitySample,
      let quantityType = sample.sampleType as? HKQuantityType,
      let unit = Self.unit(for: metricType, quantityType: quantityType)
    {
      return [
        "vendorSampleId": sample.uuid.uuidString,
        "sourceName": sample.sourceRevision.source.name,
        "sourceDevice": sample.device?.name ?? sample.sourceRevision.productType ?? "unknown",
        "metricType": metricType,
        "value": quantitySample.quantity.doubleValue(for: unit),
        "unit": Self.unitName(for: metricType),
        "startTime": formatter.string(from: sample.startDate),
        "endTime": formatter.string(from: sample.endDate),
        "timezone": timezone,
        "metadata": [:],
      ]
    }

    if let categorySample = sample as? HKCategorySample {
      return [
        "vendorSampleId": sample.uuid.uuidString,
        "sourceName": sample.sourceRevision.source.name,
        "sourceDevice": sample.device?.name ?? sample.sourceRevision.productType ?? "unknown",
        "metricType": metricType,
        "value": categorySample.value,
        "unit": "category",
        "startTime": formatter.string(from: sample.startDate),
        "endTime": formatter.string(from: sample.endDate),
        "timezone": timezone,
        "metadata": [:],
      ]
    }

    return nil
  }

  private static func objectType(for metricType: String) -> HKSampleType? {
    switch metricType {
    case "heartRateVariabilitySDNN":
      return HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)
    case "restingHeartRate":
      return HKObjectType.quantityType(forIdentifier: .restingHeartRate)
    case "heartRate":
      return HKObjectType.quantityType(forIdentifier: .heartRate)
    case "sleepAnalysis":
      return HKObjectType.categoryType(forIdentifier: .sleepAnalysis)
    case "oxygenSaturation":
      return HKObjectType.quantityType(forIdentifier: .oxygenSaturation)
    case "stepCount":
      return HKObjectType.quantityType(forIdentifier: .stepCount)
    case "appleSleepingWristTemperature":
      if #available(iOS 16.0, *) {
        return HKObjectType.quantityType(forIdentifier: .appleSleepingWristTemperature)
      }
      return nil
    case "workout":
      return HKObjectType.workoutType()
    case "activeEnergyBurned":
      return HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)
    case "appleExerciseTime":
      return HKObjectType.quantityType(forIdentifier: .appleExerciseTime)
    case "distanceWalkingRunning":
      return HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning)
    case "flightsClimbed":
      return HKObjectType.quantityType(forIdentifier: .flightsClimbed)
    case "walkingHeartRateAverage":
      return HKObjectType.quantityType(forIdentifier: .walkingHeartRateAverage)
    case "heartRateRecoveryOneMinute":
      if #available(iOS 16.0, *) {
        return HKObjectType.quantityType(forIdentifier: .heartRateRecoveryOneMinute)
      }
      return nil
    case "vo2Max":
      return HKObjectType.quantityType(forIdentifier: .vo2Max)
    case "respiratoryRate":
      return HKObjectType.quantityType(forIdentifier: .respiratoryRate)
    case "walkingSpeed":
      return HKObjectType.quantityType(forIdentifier: .walkingSpeed)
    case "walkingStepLength":
      return HKObjectType.quantityType(forIdentifier: .walkingStepLength)
    case "walkingAsymmetryPercentage":
      return HKObjectType.quantityType(forIdentifier: .walkingAsymmetryPercentage)
    case "walkingDoubleSupportPercentage":
      return HKObjectType.quantityType(forIdentifier: .walkingDoubleSupportPercentage)
    case "stairAscentSpeed":
      return HKObjectType.quantityType(forIdentifier: .stairAscentSpeed)
    case "stairDescentSpeed":
      return HKObjectType.quantityType(forIdentifier: .stairDescentSpeed)
    case "sixMinuteWalkTestDistance":
      return HKObjectType.quantityType(forIdentifier: .sixMinuteWalkTestDistance)
    case "dietaryCaffeine":
      return HKObjectType.quantityType(forIdentifier: .dietaryCaffeine)
    case "dietaryWater":
      return HKObjectType.quantityType(forIdentifier: .dietaryWater)
    case "dietaryEnergyConsumed":
      return HKObjectType.quantityType(forIdentifier: .dietaryEnergyConsumed)
    case "numberOfAlcoholicBeverages":
      return HKObjectType.quantityType(forIdentifier: .numberOfAlcoholicBeverages)
    case "atrialFibrillationBurden":
      if #available(iOS 16.0, *) {
        return HKObjectType.quantityType(forIdentifier: .atrialFibrillationBurden)
      }
      return nil
    case "abdominalCramps":
      return categoryType(rawValue: "HKCategoryTypeIdentifierAbdominalCramps")
    case "bloating":
      return categoryType(rawValue: "HKCategoryTypeIdentifierBloating")
    case "constipation":
      return categoryType(rawValue: "HKCategoryTypeIdentifierConstipation")
    case "diarrhea":
      return categoryType(rawValue: "HKCategoryTypeIdentifierDiarrhea")
    case "heartburn":
      return categoryType(rawValue: "HKCategoryTypeIdentifierHeartburn")
    case "nausea":
      return categoryType(rawValue: "HKCategoryTypeIdentifierNausea")
    case "vomiting":
      return categoryType(rawValue: "HKCategoryTypeIdentifierVomiting")
    case "appetiteChanges":
      return categoryType(rawValue: "HKCategoryTypeIdentifierAppetiteChanges")
    case "chills":
      return categoryType(rawValue: "HKCategoryTypeIdentifierChills")
    case "fatigue":
      return categoryType(rawValue: "HKCategoryTypeIdentifierFatigue")
    case "fever":
      return categoryType(rawValue: "HKCategoryTypeIdentifierFever")
    case "medicationDoseEvent":
      return categoryType(rawValue: "HKCategoryTypeIdentifierMedicationDoseEvent")
    case "highHeartRateEvent":
      return categoryType(rawValue: "HKCategoryTypeIdentifierHighHeartRateEvent")
    case "lowHeartRateEvent":
      return categoryType(rawValue: "HKCategoryTypeIdentifierLowHeartRateEvent")
    case "irregularHeartRhythmEvent":
      return categoryType(rawValue: "HKCategoryTypeIdentifierIrregularHeartRhythmEvent")
    case "sleepingBreathingDisturbance", "electrocardiogram":
      return nil
    default:
      return nil
    }
  }

  private static func categoryType(rawValue: String) -> HKCategoryType? {
    return HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: rawValue))
  }

  private static func unit(for metricType: String, quantityType: HKQuantityType) -> HKUnit? {
    switch metricType {
    case "heartRateVariabilitySDNN":
      return HKUnit.secondUnit(with: .milli)
    case "restingHeartRate", "heartRate":
      return HKUnit.count().unitDivided(by: .minute())
    case "oxygenSaturation":
      return HKUnit.percent()
    case "stepCount":
      return HKUnit.count()
    case "appleSleepingWristTemperature":
      return HKUnit.degreeCelsius()
    case "activeEnergyBurned", "dietaryEnergyConsumed":
      return HKUnit.kilocalorie()
    case "appleExerciseTime":
      return HKUnit.minute()
    case "distanceWalkingRunning", "walkingStepLength", "sixMinuteWalkTestDistance":
      return HKUnit.meter()
    case "flightsClimbed", "numberOfAlcoholicBeverages":
      return HKUnit.count()
    case "walkingHeartRateAverage", "respiratoryRate":
      return HKUnit.count().unitDivided(by: .minute())
    case "heartRateRecoveryOneMinute":
      return HKUnit.count().unitDivided(by: .minute())
    case "vo2Max":
      let massTime = HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute())
      return HKUnit.literUnit(with: .milli).unitDivided(by: massTime)
    case "walkingSpeed", "stairAscentSpeed", "stairDescentSpeed":
      return HKUnit.meter().unitDivided(by: .second())
    case "walkingAsymmetryPercentage", "walkingDoubleSupportPercentage", "atrialFibrillationBurden":
      return HKUnit.percent()
    case "dietaryCaffeine":
      return HKUnit.gramUnit(with: .milli)
    case "dietaryWater":
      return HKUnit.literUnit(with: .milli)
    default:
      return nil
    }
  }

  private static func unitName(for metricType: String) -> String {
    switch metricType {
    case "heartRateVariabilitySDNN":
      return "ms"
    case "restingHeartRate", "heartRate":
      return "count/min"
    case "oxygenSaturation":
      return "%"
    case "stepCount":
      return "count"
    case "appleSleepingWristTemperature":
      return "degC"
    case "workout", "appleExerciseTime":
      return "min"
    case "activeEnergyBurned", "dietaryEnergyConsumed":
      return "kcal"
    case "distanceWalkingRunning", "walkingStepLength", "sixMinuteWalkTestDistance":
      return "m"
    case "flightsClimbed", "numberOfAlcoholicBeverages":
      return "count"
    case "walkingHeartRateAverage", "respiratoryRate":
      return "count/min"
    case "heartRateRecoveryOneMinute":
      return "bpm_drop"
    case "vo2Max":
      return "mL/kg/min"
    case "walkingSpeed", "stairAscentSpeed", "stairDescentSpeed":
      return "m/s"
    case "walkingAsymmetryPercentage", "walkingDoubleSupportPercentage", "atrialFibrillationBurden":
      return "%"
    case "dietaryCaffeine":
      return "mg"
    case "dietaryWater":
      return "mL"
    default:
      return "unknown"
    }
  }
}
