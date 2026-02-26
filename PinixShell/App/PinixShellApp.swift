// PinixShellApp.swift
// Pinix iOS Shell — Clip 运行时外壳

import SwiftUI

@main
struct PinixShellApp: App {
    @StateObject private var clipsStore = ClipsStore()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ClipListView()
            }
            .environmentObject(clipsStore)
        }
    }
}
