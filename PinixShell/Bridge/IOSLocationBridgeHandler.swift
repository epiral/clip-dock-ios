// IOSLocationBridgeHandler.swift
// iOS 专属位置能力 Bridge Handler
//
// Actions:
//   ios.locationGet — 获取当前 GPS 坐标（单次定位）

import Foundation
import CoreLocation

@MainActor
final class IOSLocationBridgeHandler: NSObject {

    static let actions: Set<String> = ["ios.locationGet"]

    private var locationManager: CLLocationManager?
    private var locationContinuation: CheckedContinuation<[String: Any], Error>?

    func handle(
        action: String,
        body: [String: Any],
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        switch action {
        case "ios.locationGet":
            handleLocationGet(replyHandler: replyHandler)
        default:
            replyHandler(nil, "IOSLocationBridgeHandler: unknown action '\(action)'")
        }
    }

    // MARK: - ios.locationGet

    private func handleLocationGet(
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        Task { @MainActor in
            do {
                let result = try await getLocation()
                replyHandler(result, nil)
            } catch {
                replyHandler(nil, "ios.locationGet: \(error.localizedDescription)")
            }
        }
    }

    private func getLocation() async throws -> [String: Any] {
        return try await withCheckedThrowingContinuation { continuation in
            self.locationContinuation = continuation
            let manager = CLLocationManager()
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyBest
            self.locationManager = manager

            switch manager.authorizationStatus {
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
            case .authorizedWhenInUse, .authorizedAlways:
                manager.requestLocation()
            default:
                self.locationContinuation = nil
                self.locationManager = nil
                continuation.resume(throwing: IOSLocationError.denied)
            }
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension IOSLocationBridgeHandler: CLLocationManagerDelegate {

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        Task { @MainActor in
            guard let continuation = self.locationContinuation,
                  let location = locations.last else { return }
            self.locationContinuation = nil
            self.locationManager = nil

            continuation.resume(returning: [
                "lat":      location.coordinate.latitude,
                "lng":      location.coordinate.longitude,
                "accuracy": location.horizontalAccuracy,
                "altitude": location.altitude
            ])
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        Task { @MainActor in
            guard let continuation = self.locationContinuation else { return }
            self.locationContinuation = nil
            self.locationManager = nil
            continuation.resume(throwing: error)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.locationContinuation != nil else { return }
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                manager.requestLocation()
            case .denied, .restricted:
                guard let continuation = self.locationContinuation else { return }
                self.locationContinuation = nil
                self.locationManager = nil
                continuation.resume(throwing: IOSLocationError.denied)
            default:
                break
            }
        }
    }
}

// MARK: - Errors

enum IOSLocationError: LocalizedError {
    case denied
    var errorDescription: String? {
        "Location access denied. Please allow access in Settings."
    }
}
