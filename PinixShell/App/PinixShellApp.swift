// PinixShellApp.swift
// Pinix iOS Shell — Clip 运行时外壳

import SwiftUI

@main
struct PinixShellApp: App {
    @StateObject private var clipsStore = ClipsStore()
    @State private var path = NavigationPath()
    @State private var fullscreenClip: Bookmark?
    @State private var suppressList = false

    var body: some Scene {
        WindowGroup {
            ZStack {
                if !suppressList {
                    NavigationStack(path: $path) {
                        ClipListView()
                    }
                } else {
                    Color.black
                }
            }
            .environmentObject(clipsStore)
            .fullScreenCover(item: $fullscreenClip) { clip in
                ClipView(bookmark: clip, initialFullscreen: true)
            }
            .onOpenURL { url in
                handleDeepLink(url)
            }
        }
    }

    private func handleDeepLink(_ url: URL) {
        // pinix://clip/[name]?fullscreen=1
        guard url.scheme == "pinix",
              url.host == "clip",
              let clipName = url.pathComponents.dropFirst().first,
              let clip = clipsStore.clips.first(where: { $0.name == clipName })
        else { return }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let fullscreen = components?.queryItems?
            .first(where: { $0.name == "fullscreen" })?.value == "1"

        if fullscreen {
            suppressList = true
            fullscreenClip = clip
        } else {
            path = NavigationPath()
            path.append(ClipDestination(bookmark: clip, fullscreen: false))
        }
    }
}
