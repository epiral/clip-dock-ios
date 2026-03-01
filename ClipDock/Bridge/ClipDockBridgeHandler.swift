// ClipDockBridgeHandler.swift
// ClipDock gRPC Bridge — 将 JS Bridge 消息映射到 ClipService.Invoke RPC
//
// 支持两种模式：
//   action="invoke"       → 累积所有 chunk，一次性返回 { stdout, stderr, exitCode }（向后兼容）
//   action="invokeStream" → 每个 chunk 实时回调 JS（通过 streamId + evaluateJavaScript）
//
// Depends: GRPCCore, GRPCNIOTransportHTTP2, GRPCProtobuf, WebKit

import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import WebKit

@MainActor
final class ClipDockBridgeHandler {

    static let actions: Set<String> = ["invoke", "invokeStream"]

    /// 由 JSBridge 从配置注入，禁止 JS 层传入
    private var host: String
    private var token: String

    /// WKWebView 引用，用于 invokeStream 推送 chunk 到 JS
    weak var webView: WKWebView?

    init(host: String, token: String) {
        self.host = host
        self.token = token
    }

    /// 更新 host/token（当 Clip 切换或配置变更时调用）
    func updateConfig(host: String, token: String) {
        self.host = host
        self.token = token
    }

    func handle(
        action: String,
        body: [String: Any],
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        switch action {
        case "invoke":
            handleInvoke(body: body, replyHandler: replyHandler)
        case "invokeStream":
            handleInvokeStream(body: body, replyHandler: replyHandler)
        default:
            replyHandler(nil, "ClipDockBridgeHandler: unknown action \(action)")
        }
    }

    // MARK: - invoke（累积模式，向后兼容）

    private func handleInvoke(
        body: [String: Any],
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        guard let name = body["name"] as? String else {
            replyHandler(nil, "invoke: missing 'name'")
            return
        }

        let args = body["args"] as? [String] ?? []
        let stdin = body["stdin"] as? String ?? ""

        var request = Pinix_V1_InvokeRequest()
        request.name = name
        request.args = args
        request.stdin = stdin

        let metadata = makeMetadata()
        let hostString = host

        Task {
            do {
                let (hostname, port) = try Self.parseHost(hostString)
                let result: (Data, Data, Int32) = try await withGRPCClient(
                    transport: .http2NIOPosix(
                        target: .dns(host: hostname, port: port),
                        transportSecurity: .plaintext
                    )
                ) { client in
                    let clipService = Pinix_V1_ClipService.Client(wrapping: client)
                    return try await clipService.invoke(request, metadata: metadata) { response in
                        var stdoutBuf = Data()
                        var stderrBuf = Data()
                        var exitCode: Int32 = 0
                        for try await chunk in response.messages {
                            switch chunk.payload {
                            case .stdout(let data): stdoutBuf.append(data)
                            case .stderr(let data): stderrBuf.append(data)
                            case .exitCode(let code): exitCode = code
                            case nil: break
                            }
                        }
                        return (stdoutBuf, stderrBuf, exitCode)
                    }
                }

                let dict: [String: Any] = [
                    "stdout": String(data: result.0, encoding: .utf8) ?? "",
                    "stderr": String(data: result.1, encoding: .utf8) ?? "",
                    "exitCode": Int(result.2)
                ]
                replyHandler(dict, nil)
            } catch {
                replyHandler(nil, "invoke error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - invokeStream（实时流式回调）

    private func handleInvokeStream(
        body: [String: Any],
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        guard let command = body["command"] as? String,
              let streamId = body["streamId"] as? String else {
            replyHandler(nil, "invokeStream: missing 'command' or 'streamId'")
            return
        }

        // 安全检查：streamId 只允许安全字符，防止 JS 注入
        let safe = streamId.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        guard safe else {
            replyHandler(nil, "invokeStream: invalid streamId")
            return
        }

        let args = body["args"] as? [String] ?? []
        let stdin = body["stdin"] as? String ?? ""

        // 立即回复 JS（fire-and-forget，后续通过 evaluateJavaScript 回调）
        replyHandler(["streamId": streamId], nil)

        var request = Pinix_V1_InvokeRequest()
        request.name = command
        request.args = args
        request.stdin = stdin

        let metadata = makeMetadata()
        let hostString = host
        let webView = self.webView

        Task {
            do {
                let (hostname, port) = try Self.parseHost(hostString)
                try await withGRPCClient(
                    transport: .http2NIOPosix(
                        target: .dns(host: hostname, port: port),
                        transportSecurity: .plaintext
                    )
                ) { client in
                    let clipService = Pinix_V1_ClipService.Client(wrapping: client)
                    try await clipService.invoke(request, metadata: metadata) { response in
                        for try await chunk in response.messages {
                            switch chunk.payload {
                            case .stdout(let data):
                                let text = String(data: data, encoding: .utf8) ?? ""
                                let escaped = Self.escapeForJS(text)
                                await MainActor.run {
                                    webView?.evaluateJavaScript(
                                        "window.__streamCallbacks['\(streamId)']?.onChunk(\(escaped))",
                                        completionHandler: nil
                                    )
                                }
                            case .stderr:
                                break
                            case .exitCode(let code):
                                await MainActor.run {
                                    webView?.evaluateJavaScript(
                                        "window.__streamCallbacks['\(streamId)']?.onDone(\(code)); delete window.__streamCallbacks['\(streamId)']",
                                        completionHandler: nil
                                    )
                                }
                            case nil:
                                break
                            }
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    webView?.evaluateJavaScript(
                        "window.__streamCallbacks['\(streamId)']?.onDone(-1); delete window.__streamCallbacks['\(streamId)']",
                        completionHandler: nil
                    )
                }
            }
        }
    }

    // MARK: - 辅助

    private func makeMetadata() -> Metadata {
        var metadata: Metadata = [:]
        if !token.isEmpty {
            metadata.addString("Bearer \(token)", forKey: "authorization")
        }
        return metadata
    }

    /// 从 URL 字符串 (如 "http://192.168.1.79:9875") 解析 host 和 port
    nonisolated static func parseHost(_ urlString: String) throws -> (String, Int) {
        guard let url = URL(string: urlString),
              let hostname = url.host,
              let port = url.port else {
            throw NSError(
                domain: "ClipDockBridge", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid host URL: \(urlString)"]
            )
        }
        return (hostname, port)
    }

    // MARK: - JS 辅助

    /// 将字符串安全转义为 JS 字符串字面量（含引号）
    /// 通过 JSON 数组序列化再提取，确保正确处理 \n \r \t ' " \ 等
    nonisolated static func escapeForJS(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text]),
              let json = String(data: data, encoding: .utf8) else {
            // fallback：单引号包裹，基本转义
            let escaped = text
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
            return "'\(escaped)'"
        }
        // json = '["actual content"]'，取出内部的 "actual content"
        return String(json.dropFirst(1).dropLast(1))
    }
}
