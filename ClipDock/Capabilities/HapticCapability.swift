// HapticCapability.swift
// Shared haptic feedback capability — trigger UIImpactFeedbackGenerator
//
// Used by: IOSSystemBridgeHandler (JS Bridge), EdgeCommandRouter (Edge)

import UIKit

@MainActor
final class HapticCapability {

    /// Trigger haptic feedback.
    /// - Parameter style: "light", "medium" (default), "heavy", "soft", "rigid"
    func trigger(style: String = "medium") {
        let feedbackStyle: UIImpactFeedbackGenerator.FeedbackStyle
        switch style {
        case "light":   feedbackStyle = .light
        case "heavy":   feedbackStyle = .heavy
        case "soft":    feedbackStyle = .soft
        case "rigid":   feedbackStyle = .rigid
        default:        feedbackStyle = .medium
        }
        UIImpactFeedbackGenerator(style: feedbackStyle).impactOccurred()
    }
}
