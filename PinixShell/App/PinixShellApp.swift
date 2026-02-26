// PinixShellApp.swift
// Pinix iOS Shell — Clip 运行时外壳

import SwiftUI

@main
struct PinixShellApp: App {

    // TODO: 从配置/深度链接注入，目前硬编码默认值
    private let defaultHost = "http://100.66.47.40:9875"
    private let defaultClipId = "eea0aa10fbca05cb"
    private let defaultToken = "2ef025c2259cee52a6e020136d1c6606728170a7d884b2e0377e0e07df5bb073"

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
