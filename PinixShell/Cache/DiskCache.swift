// DiskCache.swift
// 磁盘缓存管理器 — 按 alias 隔离，分 web/data 两个子目录
//
// web/  → pinix-web:// 强缓存（文件内容直接写磁盘）
// data/ → pinix-data:// ETag 协商缓存（文件内容 + sidecar .meta.json）

import Foundation

final class DiskCache: Sendable {

    static let shared = DiskCache()

    /// 根目录：Library/Caches/PinixShell/clips/
    private let rootURL: URL

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        rootURL = caches.appendingPathComponent("PinixShell/clips", isDirectory: true)
    }

    // MARK: - pinix-web:// 强缓存

    func readWebCache(alias: String, path: String) -> Data? {
        let fileURL = webFileURL(alias: alias, path: path)
        return try? Data(contentsOf: fileURL)
    }

    func writeWebCache(alias: String, path: String, data: Data) {
        let fileURL = webFileURL(alias: alias, path: path)
        atomicWrite(data: data, to: fileURL)
    }

    func clearWebCache(alias: String) {
        let dir = rootURL.appendingPathComponent(alias, isDirectory: true)
            .appendingPathComponent("web", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - pinix-data:// ETag 协商缓存

    struct DataCacheEntry {
        let data: Data
        let etag: String
        let mimeType: String
    }

    func readDataCache(alias: String, path: String) -> DataCacheEntry? {
        let fileURL = dataFileURL(alias: alias, path: path)
        let metaURL = dataMetaURL(alias: alias, path: path)

        guard let data = try? Data(contentsOf: fileURL),
              let metaData = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(DataMeta.self, from: metaData)
        else { return nil }

        return DataCacheEntry(data: data, etag: meta.etag, mimeType: meta.mimeType)
    }

    func writeDataCache(alias: String, path: String, data: Data, etag: String, mimeType: String) {
        let fileURL = dataFileURL(alias: alias, path: path)
        let metaURL = dataMetaURL(alias: alias, path: path)

        atomicWrite(data: data, to: fileURL)

        let meta = DataMeta(etag: etag, mimeType: mimeType)
        if let encoded = try? JSONEncoder().encode(meta) {
            atomicWrite(data: encoded, to: metaURL)
        }
    }

    // MARK: - 内部

    private struct DataMeta: Codable {
        let etag: String
        let mimeType: String
    }

    private func webFileURL(alias: String, path: String) -> URL {
        rootURL.appendingPathComponent(alias, isDirectory: true)
            .appendingPathComponent("web", isDirectory: true)
            .appendingPathComponent(path)
    }

    private func dataFileURL(alias: String, path: String) -> URL {
        rootURL.appendingPathComponent(alias, isDirectory: true)
            .appendingPathComponent("data", isDirectory: true)
            .appendingPathComponent(path)
    }

    private func dataMetaURL(alias: String, path: String) -> URL {
        rootURL.appendingPathComponent(alias, isDirectory: true)
            .appendingPathComponent("data", isDirectory: true)
            .appendingPathComponent(path + ".meta.json")
    }

    /// 原子写入：先写临时文件再 moveItem
    private func atomicWrite(data: Data, to url: URL) {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let tmp = dir.appendingPathComponent(UUID().uuidString + ".tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try? fm.removeItem(at: url)
            try fm.moveItem(at: tmp, to: url)
        } catch {
            try? fm.removeItem(at: tmp)
        }
    }
}
