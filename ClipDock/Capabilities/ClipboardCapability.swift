// ClipboardCapability.swift
// Shared clipboard capability — read/write UIPasteboard
//
// Used by: IOSSystemBridgeHandler (JS Bridge), EdgeCommandRouter (Edge)

import UIKit

@MainActor
final class ClipboardCapability {

    /// Read current clipboard text.
    /// Returns the string or nil if empty.
    func read() -> String? {
        UIPasteboard.general.string
    }

    /// Write text to clipboard.
    func write(text: String) {
        UIPasteboard.general.string = text
    }
}
