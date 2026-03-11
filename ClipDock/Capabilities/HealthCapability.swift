// HealthCapability.swift
// Shared HealthKit capability — query health data by type, date range, limit
//
// Supported types:
//   heartRate, restingHeartRate, hrv, bloodOxygen,
//   sleep, steps, activeEnergy, bodyMass, bodyFat, bloodPressure
//
// Used by: IOSHealthBridgeHandler (JS Bridge), EdgeCommandRouter (Edge)

import Foundation
import HealthKit

@MainActor
final class HealthCapability {

    private let healthStore = HKHealthStore()

    /// Query HealthKit data.
    /// - Parameters:
    ///   - typeString: one of supportedTypes
    ///   - from: start date
    ///   - to: end date
    ///   - limit: max number of results (default 100)
    /// - Returns: { data: [[String: Any]] }
    func query(
        typeString: String,
        from: Date,
        to: Date,
        limit: Int = 100
    ) async throws -> [String: Any] {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthCapabilityError.unavailable
        }

        guard let mapping = Self.typeMapping[typeString] else {
            throw HealthCapabilityError.unsupportedType(typeString)
        }

        try await requestAuthorization(for: mapping)

        let data: [[String: Any]]
        switch mapping {
        case .quantity(let identifier, let unit):
            data = try await queryQuantity(
                identifier: identifier, unit: unit,
                from: from, to: to, limit: limit
            )
        case .category:
            data = try await querySleep(from: from, to: to, limit: limit)
        case .correlation:
            data = try await queryBloodPressure(from: from, to: to, limit: limit)
        }

        return ["data": data]
    }

    // MARK: - Authorization

    private func requestAuthorization(for mapping: TypeMapping) async throws {
        let readTypes: Set<HKObjectType>
        switch mapping {
        case .quantity(let identifier, _):
            readTypes = [HKQuantityType(identifier)]
        case .category:
            readTypes = [HKCategoryType(.sleepAnalysis)]
        case .correlation:
            readTypes = [
                HKQuantityType(.bloodPressureSystolic),
                HKQuantityType(.bloodPressureDiastolic)
            ]
        }

        do {
            try await healthStore.requestAuthorization(toShare: [], read: readTypes)
        } catch {
            throw HealthCapabilityError.authorizationFailed(error.localizedDescription)
        }
    }

    // MARK: - Query HKQuantitySample

    private func queryQuantity(
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        from: Date,
        to: Date,
        limit: Int
    ) async throws -> [[String: Any]] {
        let quantityType = HKQuantityType(identifier)
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to)

        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: quantityType, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: limit
        )

        let results = try await descriptor.result(for: healthStore)
        let formatter = ISO8601DateFormatter()

        return results.map { sample in [
            "value":     sample.quantity.doubleValue(for: unit),
            "unit":      unit.unitString,
            "startDate": formatter.string(from: sample.startDate),
            "endDate":   formatter.string(from: sample.endDate)
        ]}
    }

    // MARK: - Query Sleep (HKCategorySample)

    private func querySleep(from: Date, to: Date, limit: Int) async throws -> [[String: Any]] {
        let sleepType = HKCategoryType(.sleepAnalysis)
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to)

        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: sleepType, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: limit
        )

        let results = try await descriptor.result(for: healthStore)
        let formatter = ISO8601DateFormatter()

        return results.map { sample in [
            "value":     Self.sleepStageString(from: sample.value),
            "unit":      "stage",
            "startDate": formatter.string(from: sample.startDate),
            "endDate":   formatter.string(from: sample.endDate)
        ]}
    }

    // MARK: - Query Blood Pressure (HKCorrelation)

    private func queryBloodPressure(from: Date, to: Date, limit: Int) async throws -> [[String: Any]] {
        let bpType = HKCorrelationType(.bloodPressure)
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to)
        let mmHg = HKUnit.millimeterOfMercury()
        let formatter = ISO8601DateFormatter()

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKCorrelationQuery(
                type: bpType,
                predicate: predicate,
                samplePredicates: nil
            ) { _, results, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let sorted = (results ?? [])
                    .sorted { $0.endDate > $1.endDate }
                    .prefix(limit)

                let data: [[String: Any]] = sorted.map { corr in
                    let sys = corr.objects(for: HKQuantityType(.bloodPressureSystolic)).first as? HKQuantitySample
                    let dia = corr.objects(for: HKQuantityType(.bloodPressureDiastolic)).first as? HKQuantitySample
                    return [
                        "date": formatter.string(from: corr.endDate),
                        "sys":  sys?.quantity.doubleValue(for: mmHg) ?? 0,
                        "dia":  dia?.quantity.doubleValue(for: mmHg) ?? 0
                    ]
                }
                continuation.resume(returning: data)
            }
            healthStore.execute(query)
        }
    }

    // MARK: - Sleep Stage Mapping

    private static func sleepStageString(from value: Int) -> String {
        guard let v = HKCategoryValueSleepAnalysis(rawValue: value) else { return "unknown" }
        switch v {
        case .inBed:             return "inBed"
        case .asleepUnspecified: return "asleep"
        case .awake:             return "awake"
        case .asleepCore:        return "asleepCore"
        case .asleepDeep:        return "asleepDeep"
        case .asleepREM:         return "asleepREM"
        @unknown default:        return "unknown"
        }
    }

    // MARK: - ISO8601 Parsing (with/without fractional seconds)

    nonisolated static func parseISO8601(_ string: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: string) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: string)
    }

    // MARK: - Type Whitelist

    enum TypeMapping {
        case quantity(HKQuantityTypeIdentifier, HKUnit)
        case category
        case correlation
    }

    static let typeMapping: [String: TypeMapping] = [
        "heartRate":        .quantity(.heartRate,                    .count().unitDivided(by: .minute())),
        "restingHeartRate": .quantity(.restingHeartRate,             .count().unitDivided(by: .minute())),
        "hrv":              .quantity(.heartRateVariabilitySDNN,     .secondUnit(with: .milli)),
        "bloodOxygen":      .quantity(.oxygenSaturation,            .percent()),
        "sleep":            .category,
        "steps":            .quantity(.stepCount,                    .count()),
        "activeEnergy":     .quantity(.activeEnergyBurned,          .kilocalorie()),
        "bodyMass":         .quantity(.bodyMass,                    .gramUnit(with: .kilo)),
        "bodyFat":          .quantity(.bodyFatPercentage,           .percent()),
        "bloodPressure":    .correlation
    ]

    static let supportedTypes = [
        "heartRate", "restingHeartRate", "hrv", "bloodOxygen",
        "sleep", "steps", "activeEnergy", "bodyMass", "bodyFat", "bloodPressure"
    ]
}

// MARK: - HealthCapabilityError

enum HealthCapabilityError: LocalizedError {
    case unavailable
    case unsupportedType(String)
    case authorizationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "HealthKit is not available on this device"
        case .unsupportedType(let t):
            return "Unsupported health type '\(t)'. Supported: \(HealthCapability.supportedTypes.joined(separator: ", "))"
        case .authorizationFailed(let reason):
            return "HealthKit authorization failed: \(reason)"
        }
    }
}
