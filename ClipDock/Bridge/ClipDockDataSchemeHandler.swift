// ClipDockDataSchemeHandler.swift
// pinix-data:// URL Scheme — 通过 ClipService.ReadFile（server streaming）读取 {workdir}/data/ 下的文件
//
// URL 格式：pinix-data://clip-id/voice.mp3 → ReadFile(path: "data/voice.mp3")
// 支持 Range 请求（200/206/416），只读

import WebKit
import Connect

@MainActor
final class ClipDockDataSchemeHandler: NSObject, WKURLSchemeHandler {

    private let host: String
    private let token: String
    private let alias: String
    private var stoppedTasks = Set<ObjectIdentifier>()

    init(host: String, token: String, alias: String) {
        self.host = host
        self.token = token
        self.alias = alias
        super.init()
    }

    nonisolated func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        Task { @MainActor in
            let taskId = ObjectIdentifier(urlSchemeTask as AnyObject)

            guard let requestURL = urlSchemeTask.request.url else {
                urlSchemeTask.didFailWithError(self.makeError("无效 URL"))
                return
            }

            let path = requestURL.path
            guard !path.isEmpty, path != "/" else {
                urlSchemeTask.didFailWithError(self.makeError("路径不能为空"))
                return
            }

            // 转为 workdir 相对路径：data/path/to/file
            let relativePath = "data" + path
            let rangeHeader = urlSchemeTask.request.value(forHTTPHeaderField: "Range")

            do {
                if let rangeHeader {
                    // Range 请求：不走缓存，维持原逻辑
                    try await self.handleRangeRequest(
                        urlSchemeTask: urlSchemeTask, taskId: taskId,
                        url: requestURL, path: relativePath, rangeHeader: rangeHeader
                    )
                } else {
                    // 全量读取 — ETag 协商缓存
                    let cached = DiskCache.shared.readDataCache(alias: self.alias, path: relativePath)
                    let cachedEtag = cached?.etag ?? ""

                    let fileData = try await self.readFile(
                        path: relativePath, offset: 0, length: 0, ifNoneMatch: cachedEtag
                    )

                    guard !self.stoppedTasks.contains(taskId) else { return }

                    if fileData.notModified, let cached {
                        // 服务端确认未变 → 用本地缓存返回
                        self.respond200(
                            urlSchemeTask: urlSchemeTask, url: requestURL,
                            data: cached.data, mimeType: cached.mimeType,
                            totalSize: Int(cached.data.count)
                        )
                    } else {
                        // 新数据 → 写缓存后返回
                        if !fileData.etag.isEmpty {
                            DiskCache.shared.writeDataCache(
                                alias: self.alias, path: relativePath,
                                data: fileData.data, etag: fileData.etag, mimeType: fileData.mimeType
                            )
                        }
                        self.respond200(
                            urlSchemeTask: urlSchemeTask, url: requestURL,
                            data: fileData.data, mimeType: fileData.mimeType,
                            totalSize: Int(fileData.totalSize)
                        )
                    }
                }
            } catch {
                guard !self.stoppedTasks.contains(taskId) else { return }
                urlSchemeTask.didFailWithError(error)
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        Task { @MainActor in
            let taskId = ObjectIdentifier(urlSchemeTask as AnyObject)
            self.stoppedTasks.insert(taskId)
        }
    }

    // MARK: - Range 请求处理

    private func handleRangeRequest(
        urlSchemeTask: WKURLSchemeTask, taskId: ObjectIdentifier,
        url: URL, path: String, rangeHeader: String
    ) async throws {
        // 先做一次小读取获取 totalSize（offset=0, length=1）
        let probe = try await readFile(path: path, offset: 0, length: 1)
        let totalLength = Int(probe.totalSize)

        guard let range = parseRangeHeader(rangeHeader, totalLength: totalLength) else {
            guard !stoppedTasks.contains(taskId) else { return }
            respond416(urlSchemeTask: urlSchemeTask, url: url, totalLength: totalLength)
            return
        }

        // 按 Range 精确读取
        let result = try await readFile(
            path: path,
            offset: Int64(range.lowerBound),
            length: Int64(range.count)
        )

        guard !stoppedTasks.contains(taskId) else { return }

        respond206(
            urlSchemeTask: urlSchemeTask, url: url, data: result.data,
            range: range, totalLength: totalLength, mimeType: result.mimeType
        )
    }

    // MARK: - ReadFile streaming

    private struct FileResult {
        let data: Data
        let mimeType: String
        let totalSize: Int64
        let etag: String
        let notModified: Bool
    }

    /// 通过 ClipService.ReadFile（server streaming）读取文件
    private func readFile(path: String, offset: Int64, length: Int64, ifNoneMatch: String = "") async throws -> FileResult {
        let client = makeClient()

        var request = Pinix_V1_ReadFileRequest()
        request.path = path
        request.offset = offset
        request.length = length
        if !ifNoneMatch.isEmpty {
            request.ifNoneMatch = ifNoneMatch
        }

        var headers: Connect.Headers = [:]
        if !token.isEmpty {
            headers["authorization"] = ["Bearer \(token)"]
        }

        let stream = client.readFile(headers: headers)
        try stream.send(request)

        var chunks: [(offset: Int64, data: Data)] = []
        var mimeType = "application/octet-stream"
        var totalSize: Int64 = 0
        var etag = ""
        var notModified = false
        var streamError: Error?

        for await result in stream.results() {
            switch result {
            case .headers:
                break
            case .message(let chunk):
                if chunk.notModified {
                    notModified = true
                    if !chunk.etag.isEmpty { etag = chunk.etag }
                    if !chunk.mimeType.isEmpty { mimeType = chunk.mimeType }
                } else {
                    chunks.append((offset: chunk.offset, data: chunk.data))
                    if !chunk.mimeType.isEmpty { mimeType = chunk.mimeType }
                    if chunk.totalSize > 0 { totalSize = chunk.totalSize }
                    if !chunk.etag.isEmpty { etag = chunk.etag }
                }
            case .complete(_, let error, _):
                if let error { streamError = error }
            }
        }

        if let streamError {
            throw makeError("ReadFile 失败: \(streamError)")
        }

        if notModified {
            return FileResult(data: Data(), mimeType: mimeType, totalSize: 0, etag: etag, notModified: true)
        }

        // 按 offset 排序后拼合
        chunks.sort { $0.offset < $1.offset }
        var assembled = Data()
        for chunk in chunks {
            assembled.append(chunk.data)
        }

        return FileResult(data: assembled, mimeType: mimeType, totalSize: totalSize, etag: etag, notModified: false)
    }

    // MARK: - 响应辅助

    private func respond200(urlSchemeTask: WKURLSchemeTask, url: URL, data: Data, mimeType: String, totalSize: Int) {
        let headers: [String: String] = [
            "Content-Type": mimeType,
            "Content-Length": "\(data.count)",
            "Accept-Ranges": "bytes",
            "Access-Control-Allow-Origin": "*"
        ]
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    private func respond206(urlSchemeTask: WKURLSchemeTask, url: URL, data: Data,
                            range: Range<Int>, totalLength: Int, mimeType: String) {
        let headers: [String: String] = [
            "Content-Type": mimeType,
            "Content-Length": "\(data.count)",
            "Content-Range": "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(totalLength)",
            "Accept-Ranges": "bytes",
            "Access-Control-Allow-Origin": "*"
        ]
        let response = HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: headers)!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    private func respond416(urlSchemeTask: WKURLSchemeTask, url: URL, totalLength: Int) {
        let headers: [String: String] = [
            "Content-Range": "bytes */\(totalLength)",
            "Accept-Ranges": "bytes"
        ]
        let response = HTTPURLResponse(url: url, statusCode: 416, httpVersion: "HTTP/1.1", headerFields: headers)!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didFinish()
    }

    // MARK: - Range 解析

    /// 解析 Range 头，返回半开区间 [start, end)
    /// 支持格式：bytes=0-1023, bytes=1024-, bytes=-512
    private func parseRangeHeader(_ header: String, totalLength: Int) -> Range<Int>? {
        guard header.hasPrefix("bytes=") else { return nil }
        let spec = String(header.dropFirst("bytes=".count))
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }

        let startStr = parts[0].trimmingCharacters(in: .whitespaces)
        let endStr = parts[1].trimmingCharacters(in: .whitespaces)

        let start: Int
        let end: Int

        if startStr.isEmpty {
            guard let suffix = Int(endStr), suffix > 0 else { return nil }
            start = max(totalLength - suffix, 0)
            end = totalLength
        } else if endStr.isEmpty {
            guard let s = Int(startStr), s < totalLength else { return nil }
            start = s
            end = totalLength
        } else {
            guard let s = Int(startStr), let e = Int(endStr), s <= e else { return nil }
            start = s
            end = min(e + 1, totalLength)
        }

        guard start < end, start < totalLength else { return nil }
        return start..<end
    }

    // MARK: - RPC Client

    private func makeClient() -> Pinix_V1_ClipServiceClient {
        let protocolClient = ProtocolClient(
            httpClient: URLSessionHTTPClient(),
            config: ProtocolClientConfig(
                host: host,
                networkProtocol: .connect,
                codec: ProtoCodec()
            )
        )
        return Pinix_V1_ClipServiceClient(client: protocolClient)
    }

    // MARK: - 错误辅助

    private func makeError(_ message: String) -> NSError {
        NSError(domain: "ClipDockDataScheme", code: -1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
