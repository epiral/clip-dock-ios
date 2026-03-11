// IOSHealthBridgeHandler.swift
// iOS 专属健康数据 Bridge Handler — thin wrapper over HealthCapability
//
// Actions:
//   ios.healthQuery — 查询 HealthKit 数据

import Foundation

@MainActor
final class IOSHealthBridgeHandler {

    static let actions: Set<String> = ["ios.healthQuery"]

    private let capability = HealthCapability()

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
        guard let typeString = body["type"] as? String else {
            replyHandler(nil, "ios.healthQuery: missing 'type'. Supported: \(HealthCapability.supportedTypes.joined(separator: ", "))")
            return
        }

        guard HealthCapability.typeMapping[typeString] != nil else {
            replyHandler(nil, "ios.healthQuery: unsupported type '\(typeString)'. Supported: \(HealthCapability.supportedTypes.joined(separator: ", "))")
            return
        }

        guard let fromString = body["from"] as? String,
              let from = HealthCapability.parseISO8601(fromString) else {
            replyHandler(nil, "ios.healthQuery: missing or invalid 'from' (ISO8601, e.g. 2024-01-01T00:00:00Z)")
            return
        }

        guard let toString = body["to"] as? String,
              let to = HealthCapability.parseISO8601(toString) else {
            replyHandler(nil, "ios.healthQuery: missing or invalid 'to' (ISO8601)")
            return
        }

        let limit = body["limit"] as? Int ?? 100

        Task {
            do {
                let result = try await capability.query(
                    typeString: typeString,
                    from: from,
                    to: to,
                    limit: limit
                )
                replyHandler(result, nil)
            } catch {
                replyHandler(nil, "ios.healthQuery: \(error.localizedDescription)")
            }
        }
    }
}
