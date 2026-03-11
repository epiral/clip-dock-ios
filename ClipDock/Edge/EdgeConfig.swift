// EdgeConfig.swift
// Edge module configuration — persisted to Documents/edge-config.json
//
// Fields:
//   enabled    — whether EdgeModule should connect on app launch
//   serverURL  — Pinix Server URL (e.g. "http://192.168.1.79:9875")
//   superToken — Super Token for EdgeService authentication

import Foundation

struct EdgeConfig: Codable {
    var enabled: Bool = false
    var serverURL: String = ""
    var superToken: String = ""

    // MARK: - Persistence

    private static var fileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("edge-config.json")
    }

    /// Load config from disk. Returns default config if file doesn't exist.
    static func load() -> EdgeConfig {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return EdgeConfig()
        }
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(EdgeConfig.self, from: data)
        } catch {
            print("[Edge] Failed to load config: \(error)")
            return EdgeConfig()
        }
    }

    /// Save config to disk.
    func save() {
        do {
            let data = try JSONEncoder().encode(self)
            try data.write(to: Self.fileURL, options: .atomic)
        } catch {
            print("[Edge] Failed to save config: \(error)")
        }
    }
}
