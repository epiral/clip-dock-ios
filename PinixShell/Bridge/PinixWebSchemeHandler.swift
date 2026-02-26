// PinixWebSchemeHandler.swift
// pinix-web:// URL Scheme — 通过 ClipService.ReadFile（server streaming）加载 {workdir}/web/ 下的文件
//
// URL 格式：pinix-web://clip-id/index.html → ReadFile(path: "web/index.html")
// 只读，不做写操作

import WebKit
import Connect

class PinixWebSchemeHandler: NSObject, WKURLSchemeHandler {

    private let host: String
    private let token: String
    private var stoppedTasks = Set<ObjectIdentifier>()

    init(host: String, token: String) {
        self.host = host
        self.token = token
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let taskId = ObjectIdentifier(urlSchemeTask as AnyObject)

        guard let requestURL = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(makeError("无效 URL"))
            return
        }

        // pinix-web://clip-id/path/to/file → path = /path/to/file
        let path = requestURL.path
        guard !path.isEmpty, path != "/" else {
            urlSchemeTask.didFailWithError(makeError("路径不能为空"))
            return
        }

        // 转为 workdir 相对路径：直接去掉开头 /
        let relativePath = String(path.dropFirst())

        Task {
            do {
                let fileData = try await self.readFile(path: relativePath)

                guard !self.stoppedTasks.contains(taskId) else { return }

                let headers: [String: String] = [
                    "Content-Type": fileData.mimeType,
                    "Content-Length": "\(fileData.data.count)",
                    "Access-Control-Allow-Origin": "*"
                ]
                let response = HTTPURLResponse(
                    url: requestURL, statusCode: 200,
                    httpVersion: "HTTP/1.1", headerFields: headers
                )!
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(fileData.data)
                urlSchemeTask.didFinish()
            } catch {
                guard !self.stoppedTasks.contains(taskId) else { return }
                urlSchemeTask.didFailWithError(error)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let taskId = ObjectIdentifier(urlSchemeTask as AnyObject)
        stoppedTasks.insert(taskId)
    }

    // MARK: - ReadFile streaming

    private struct FileResult {
        let data: Data
        let mimeType: String
    }

    /// 通过 ClipService.ReadFile（server streaming）读取文件，收集所有 chunk 拼合
    private func readFile(path: String) async throws -> FileResult {
        let client = makeClient()

        var request = Pinix_V1_ReadFileRequest()
        request.path = path

        var headers: Connect.Headers = [:]
        if !token.isEmpty {
            headers["authorization"] = ["Bearer \(token)"]
        }

        let stream = client.readFile(headers: headers)
        try stream.send(request)

        var chunks: [(offset: Int64, data: Data)] = []
        var mimeType = "application/octet-stream"
        var streamError: Error?

        for await result in stream.results() {
            switch result {
            case .headers:
                break
            case .message(let chunk):
                chunks.append((offset: chunk.offset, data: chunk.data))
                if !chunk.mimeType.isEmpty {
                    mimeType = chunk.mimeType
                }
            case .complete(_, let error, _):
                if let error {
                    streamError = error
                }
            }
        }

        if let streamError {
            throw makeError("ReadFile 失败: \(streamError)")
        }

        // 按 offset 排序后拼合
        chunks.sort { $0.offset < $1.offset }
        var assembled = Data()
        for chunk in chunks {
            assembled.append(chunk.data)
        }

        guard !assembled.isEmpty else {
            throw makeError("文件为空或不存在: \(path)")
        }

        return FileResult(data: assembled, mimeType: mimeType)
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
        NSError(domain: "PinixWebScheme", code: -1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
