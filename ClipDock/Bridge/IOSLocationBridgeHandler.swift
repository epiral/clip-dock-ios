// IOSLocationBridgeHandler.swift
// iOS 专属位置能力 Bridge Handler — thin wrapper over LocationCapability
//
// Actions:
//   ios.locationGet — 获取当前 GPS 坐标（单次定位）

import Foundation

@MainActor
final class IOSLocationBridgeHandler {

    static let actions: Set<String> = ["ios.locationGet"]

    private let capability = LocationCapability()

    func handle(
        action: String,
        body: [String: Any],
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        switch action {
        case "ios.locationGet":
            Task { @MainActor in
                do {
                    let result = try await capability.getLocation()
                    replyHandler(result, nil)
                } catch {
                    replyHandler(nil, "ios.locationGet: \(error.localizedDescription)")
                }
            }
        default:
            replyHandler(nil, "IOSLocationBridgeHandler: unknown action '\(action)'")
        }
    }
}
