// ClipConfig.swift
// Clip 配置模型 — 对应 clips.json 中的单个 Clip 条目

import Foundation

struct ClipConfig: Codable, Identifiable, Equatable, Hashable {
    var id: String { alias }
    var alias: String   // 显示名，如 "Notes"
    var host: String    // IP 或域名，如 "100.66.47.40"
    var port: Int       // 端口号
    var token: String   // Clip 鉴权 token

    var baseURL: String { "http://\(host):\(port)" }

    enum CodingKeys: String, CodingKey {
        case alias, host, port, token
    }
}

// MARK: - Navigation destination (carries per-navigation fullscreen flag)

struct ClipDestination: Hashable {
    let config: ClipConfig
    let fullscreen: Bool
}
