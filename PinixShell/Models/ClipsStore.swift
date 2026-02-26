// ClipsStore.swift
// Clip 列表持久化管理 — 读写 Documents/clips.json，提供 CRUD 操作

import Foundation

@MainActor
final class ClipsStore: ObservableObject {
    @Published private(set) var clips: [ClipConfig] = []

    private let fileURL: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.fileURL = docs.appendingPathComponent("clips.json")
        self.clips = Self.load(from: fileURL)
    }

    // MARK: - CRUD

    func addClip(_ clip: ClipConfig) {
        clips.append(clip)
        save()
    }

    func updateClip(_ clip: ClipConfig) {
        guard let idx = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        clips[idx] = clip
        save()
    }

    func deleteClip(_ clip: ClipConfig) {
        clips.removeAll { $0.id == clip.id }
        save()
    }

    // MARK: - 持久化

    private func save() {
        let wrapper = ClipsFile(clips: clips)
        guard let data = try? JSONEncoder().encode(wrapper) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func load(from url: URL) -> [ClipConfig] {
        guard let data = try? Data(contentsOf: url),
              let wrapper = try? JSONDecoder().decode(ClipsFile.self, from: data) else {
            return []
        }
        return wrapper.clips
    }
}

// clips.json 根结构
private struct ClipsFile: Codable {
    let clips: [ClipConfig]
}
