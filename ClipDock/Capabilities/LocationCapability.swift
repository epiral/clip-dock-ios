// LocationCapability.swift
// Shared location capability — wraps CLLocationManager for single-shot GPS fix
//
// Used by: IOSLocationBridgeHandler (JS Bridge), EdgeCommandRouter (Edge)

import Foundation
import CoreLocation

@MainActor
final class LocationCapability: NSObject {

    private var locationManager: CLLocationManager?
    private var locationContinuation: CheckedContinuation<[String: Any], Error>?

    /// Get current GPS coordinates (single-shot).
    /// Returns: { lat, lng, accuracy, altitude }
    func getLocation() async throws -> [String: Any] {
        guard locationContinuation == nil else {
            throw LocationCapabilityError.alreadyInProgress
        }
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
                continuation.resume(throwing: LocationCapabilityError.denied)
            }
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationCapability: CLLocationManagerDelegate {

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
                continuation.resume(throwing: LocationCapabilityError.denied)
            default:
                break
            }
        }
    }
}

// MARK: - Errors

enum LocationCapabilityError: LocalizedError {
    case denied
    case alreadyInProgress

    var errorDescription: String? {
        switch self {
        case .denied:            return "Location access denied. Please allow access in Settings."
        case .alreadyInProgress: return "Location request already in progress."
        }
    }
}
