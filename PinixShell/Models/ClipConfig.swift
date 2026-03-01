// ClipConfig.swift
// Bookmark 模型 — 对应 clips.json 中的单个 Clip 书签，与 Desktop 格式统一

import Foundation

struct Bookmark: Codable, Identifiable, Equatable, Hashable {
    var id: String { name }
    var name: String       // 显示名，如 "Notes"
    var server_url: String // 完整服务地址，如 "http://100.66.47.40:9875"
    var token: String      // Clip 鉴权 token

    enum CodingKeys: String, CodingKey {
        case name, server_url, token
    }
}

// MARK: - Navigation destination (carries per-navigation fullscreen flag)

struct ClipDestination: Hashable {
    let bookmark: Bookmark
    let fullscreen: Bool
}
