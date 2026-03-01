// ClipsStore.swift
// Bookmark 列表持久化管理 — 读写 Documents/clips.json，提供 CRUD 操作
// 格式与 Desktop 统一：{clips: [{name, server_url, token}, ...]}

import Foundation

@MainActor
final class ClipsStore: ObservableObject {
    @Published private(set) var clips: [Bookmark] = []

    private let fileURL: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.fileURL = docs.appendingPathComponent("clips.json")
        self.clips = Self.load(from: fileURL)
    }

    // MARK: - CRUD

    func addClip(_ clip: Bookmark) {
        clips.append(clip)
        save()
    }

    func updateClip(_ clip: Bookmark) {
        guard let idx = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        clips[idx] = clip
        save()
    }

    func deleteClip(_ clip: Bookmark) {
        clips.removeAll { $0.id == clip.id }
        save()
    }

    // MARK: - JSON Import

    /// 支持格式：
    /// - 包装格式：`{"clips":[{name, server_url, token}, ...]}`
    /// - 单条：`{name, server_url, token}`
    /// - 数组：`[{name, server_url, token}, ...]`
    /// 跳过 name 已存在的条目，返回导入数量
    @discardableResult
    func importFromJSON(_ jsonString: String) throws -> Int {
        guard let data = jsonString.data(using: .utf8) else {
            throw ImportError.invalidJSON
        }

        let bookmarks: [Bookmark]
        let decoder = JSONDecoder()

        if let wrapper = try? decoder.decode(BookmarksFile.self, from: data) {
            bookmarks = wrapper.clips
        } else if let single = try? decoder.decode(Bookmark.self, from: data) {
            bookmarks = [single]
        } else if let array = try? decoder.decode([Bookmark].self, from: data) {
            bookmarks = array
        } else {
            throw ImportError.invalidJSON
        }

        var imported = 0
        for bm in bookmarks {
            if clips.contains(where: { $0.name == bm.name }) { continue }
            clips.append(bm)
            imported += 1
        }

        if imported > 0 { save() }
        return imported
    }

    enum ImportError: LocalizedError {
        case invalidJSON
        var errorDescription: String? {
            switch self {
            case .invalidJSON: return "无法解析 JSON，请检查格式"
            }
        }
    }

    // MARK: - 持久化

    private func save() {
        let wrapper = BookmarksFile(clips: clips)
        guard let data = try? JSONEncoder().encode(wrapper) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func load(from url: URL) -> [Bookmark] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()

        // 新格式：{clips: [{name, server_url, token}]}
        if let wrapper = try? decoder.decode(BookmarksFile.self, from: data) {
            return wrapper.clips
        }

        // 旧格式迁移：{clips: [{alias, host, port, token}]}
        if let legacy = try? decoder.decode(LegacyClipsFile.self, from: data) {
            let migrated = legacy.clips.compactMap { $0.toBookmark() }
            if !migrated.isEmpty {
                let wrapper = BookmarksFile(clips: migrated)
                if let newData = try? JSONEncoder().encode(wrapper) {
                    try? newData.write(to: url, options: .atomic)
                }
            }
            return migrated
        }

        return []
    }
}

// MARK: - clips.json 根结构

private struct BookmarksFile: Codable {
    let clips: [Bookmark]
}

// MARK: - 旧格式迁移

private struct LegacyClipsFile: Codable {
    let clips: [LegacyClipConfig]
}

private struct LegacyClipConfig: Codable {
    let alias: String
    let host: String
    let port: Int
    let token: String

    func toBookmark() -> Bookmark {
        Bookmark(name: alias, server_url: "http://\(host):\(port)", token: token)
    }
}
