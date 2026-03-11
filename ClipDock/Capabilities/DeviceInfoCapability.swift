// DeviceInfoCapability.swift
// Device info capability — UIDevice model, OS, battery, screen info
//
// Used by: EdgeCommandRouter (Edge)

import UIKit

@MainActor
final class DeviceInfoCapability {

    /// Get device information.
    /// Returns: { name, model, systemName, systemVersion, batteryLevel, batteryState,
    ///            screenWidth, screenHeight, screenScale }
    func getInfo() -> [String: Any] {
        let device = UIDevice.current

        // Enable battery monitoring to read level/state
        let wasBatteryMonitoringEnabled = device.isBatteryMonitoringEnabled
        device.isBatteryMonitoringEnabled = true

        let batteryLevel = device.batteryLevel
        let batteryState: String
        switch device.batteryState {
        case .unknown:    batteryState = "unknown"
        case .unplugged:  batteryState = "unplugged"
        case .charging:   batteryState = "charging"
        case .full:       batteryState = "full"
        @unknown default: batteryState = "unknown"
        }

        // Restore previous monitoring state
        device.isBatteryMonitoringEnabled = wasBatteryMonitoringEnabled

        let screen = UIScreen.main
        return [
            "name":          device.name,
            "model":         device.model,
            "systemName":    device.systemName,
            "systemVersion": device.systemVersion,
            "batteryLevel":  batteryLevel,
            "batteryState":  batteryState,
            "screenWidth":   screen.bounds.width,
            "screenHeight":  screen.bounds.height,
            "screenScale":   screen.scale
        ]
    }
}
