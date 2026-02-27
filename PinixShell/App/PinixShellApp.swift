// PinixShellApp.swift
// Pinix iOS Shell — Clip 运行时外壳

import SwiftUI

@main
struct PinixShellApp: App {
    @StateObject private var clipsStore = ClipsStore()
    @State private var path = NavigationPath()

    var body: some Scene {
        WindowGroup {
            NavigationStack(path: $path) {
                ClipListView()
            }
            .environmentObject(clipsStore)
            .onOpenURL { url in
                // pinix://clip/[alias]?fullscreen=1
                guard url.scheme == "pinix",
                      url.host == "clip",
                      let alias = url.pathComponents.dropFirst().first,
                      let clip = clipsStore.clips.first(where: { $0.alias == alias })
                else { return }

                let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                let fullscreen = components?.queryItems?
                    .first(where: { $0.name == "fullscreen" })?.value == "1"

                path = NavigationPath()
                path.append(ClipDestination(config: clip, fullscreen: fullscreen))
            }
        }
    }
}
