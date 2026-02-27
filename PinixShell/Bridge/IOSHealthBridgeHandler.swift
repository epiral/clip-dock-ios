// IOSHealthBridgeHandler.swift
// iOS 专属健康数据 Bridge Handler
//
// Actions:
//   ios.healthQuery — 查询 HealthKit 数据
//
// 支持的类型：
//   heartRate, restingHeartRate, hrv, bloodOxygen,
//   sleep, steps, activeEnergy, bodyMass, bodyFat, bloodPressure

import Foundation
import HealthKit

@MainActor
final class IOSHealthBridgeHandler {

    static let actions: Set<String> = ["ios.healthQuery"]

    private let healthStore = HKHealthStore()

    func handle(
        action: String,
        body: [String: Any],
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        switch action {
        case "ios.healthQuery":
            handleQuery(body: body, replyHandler: replyHandler)
        default:
            replyHandler(nil, "IOSHealthBridgeHandler: unknown action '\(action)'")
        }
    }

    // MARK: - ios.healthQuery

    private func handleQuery(
        body: [String: Any],
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        guard HKHealthStore.isHealthDataAvailable() else {
            replyHandler(nil, "ios.healthQuery: HealthKit is not available on this device")
            return
        }

        guard let typeString = body["type"] as? String else {
            replyHandler(nil, "ios.healthQuery: missing 'type'. Supported: \(Self.supportedTypes.joined(separator: ", "))")
            return
        }

        guard let mapping = Self.typeMapping[typeString] else {
            replyHandler(nil, "ios.healthQuery: unsupported type '\(typeString)'. Supported: \(Self.supportedTypes.joined(separator: ", "))")
            return
        }

        guard let fromString = body["from"] as? String,
              let from = Self.parseISO8601(fromString) else {
            replyHandler(nil, "ios.healthQuery: missing or invalid 'from' (ISO8601, e.g. 2024-01-01T00:00:00Z)")
            return
        }

        guard let toString = body["to"] as? String,
              let to = Self.parseISO8601(toString) else {
            replyHandler(nil, "ios.healthQuery: missing or invalid 'to' (ISO8601)")
            return
        }

        let limit = body["limit"] as? Int ?? 100

        Task {
            do {
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

                replyHandler(["data": data], nil)
            } catch let error as IOSHealthBridgeError {
                replyHandler(nil, error.localizedDescription)
            } catch {
                replyHandler(nil, "ios.healthQuery: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - 授权

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
            throw IOSHealthBridgeError.authorizationFailed(error.localizedDescription)
        }
    }

    // MARK: - 查询 HKQuantitySample

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

    // MARK: - 查询睡眠数据（HKCategorySample）

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

    // MARK: - 查询血压数据（HKCorrelation）

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

    // MARK: - 睡眠阶段映射

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

    // MARK: - ISO8601 解析（兼容带/不带毫秒）

    private static func parseISO8601(_ string: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: string) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: string)
    }

    // MARK: - 类型白名单

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

// MARK: - IOSHealthBridgeError

enum IOSHealthBridgeError: LocalizedError {
    case authorizationFailed(String)

    var errorDescription: String? {
        switch self {
        case .authorizationFailed(let reason):
            return "HealthKit authorization failed: \(reason)"
        }
    }
}
