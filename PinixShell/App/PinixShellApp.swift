// PinixShellApp.swift
// Pinix iOS Shell — Clip 运行时外壳

import SwiftUI

@main
struct PinixShellApp: App {

    // TODO: 从配置/深度链接注入，目前硬编码默认值
    private let defaultHost = "http://100.66.47.40:5005"
    private let defaultClipId = "test-clip"
    private let defaultToken = "REDACTED_SUPER_TOKEN"

    var body: some Scene {
        WindowGroup {
            ClipView(
                clipId: defaultClipId,
                host: defaultHost,
                token: defaultToken
            )
        }
    }
}
