// ClipDockBridgeHandler.swift
// ClipDock Connect-RPC Bridge — 将 JS Bridge 消息映射到 ClipService.Invoke RPC
//
// 支持两种模式：
//   action="invoke"       → 累积所有 chunk，一次性返回 { stdout, stderr, exitCode }（向后兼容）
//   action="invokeStream" → 每个 chunk 实时回调 JS（通过 streamId + evaluateJavaScript）
//
// Depends: Connect, PinixClient (gen), JSBridge, WebKit

import Foundation
import Connect
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

    private func makeClient() -> Pinix_V1_ClipServiceClient {
        let protocolClient = ProtocolClient(
            httpClient: URLSessionHTTPClient(),
            config: ProtocolClientConfig(
                host: host,
                networkProtocol: .grpcWeb,
                codec: ProtoCodec()
            )
        )
        return Pinix_V1_ClipServiceClient(client: protocolClient)
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

        var headers: Connect.Headers = [:]
        if !token.isEmpty {
            headers["authorization"] = ["Bearer \(token)"]
        }

        let client = makeClient()

        Task {
            let stream = client.invoke(headers: headers)
            do {
                try stream.send(request)
            } catch {
                replyHandler(nil, "invoke error: \(error.localizedDescription)")
                return
            }

            var stdoutBuf = Data()
            var stderrBuf = Data()
            var exitCode: Int32 = 0
            var streamError: Error?

            for await result in stream.results() {
                switch result {
                case .headers:
                    break
                case .message(let chunk):
                    switch chunk.payload {
                    case .stdout(let data): stdoutBuf.append(data)
                    case .stderr(let data): stderrBuf.append(data)
                    case .exitCode(let code): exitCode = code
                    case nil: break
                    }
                case .complete(_, let error, _):
                    if let error { streamError = error }
                }
            }

            if let streamError {
                replyHandler(nil, "invoke error: \(streamError.localizedDescription)")
                return
            }

            let result: [String: Any] = [
                "stdout": String(data: stdoutBuf, encoding: .utf8) ?? "",
                "stderr": String(data: stderrBuf, encoding: .utf8) ?? "",
                "exitCode": Int(exitCode)
            ]
            replyHandler(result, nil)
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

        var headers: Connect.Headers = [:]
        if !token.isEmpty {
            headers["authorization"] = ["Bearer \(token)"]
        }

        let client = makeClient()

        Task { [weak self] in
            guard let self else { return }

            let stream = client.invoke(headers: headers)
            do {
                try stream.send(request)
            } catch {
                self.evalJS("window.__streamCallbacks['\(streamId)']?.onDone(-1); delete window.__streamCallbacks['\(streamId)']")
                return
            }

            for await result in stream.results() {
                switch result {
                case .headers:
                    break
                case .message(let chunk):
                    switch chunk.payload {
                    case .stdout(let data):
                        let text = String(data: data, encoding: .utf8) ?? ""
                        let escaped = Self.escapeForJS(text)
                        self.evalJS("window.__streamCallbacks['\(streamId)']?.onChunk(\(escaped))")
                    case .stderr:
                        // stderr 不回调 onChunk，仅记录
                        break
                    case .exitCode(let code):
                        self.evalJS("window.__streamCallbacks['\(streamId)']?.onDone(\(code)); delete window.__streamCallbacks['\(streamId)']")
                    case nil:
                        break
                    }
                case .complete(_, let error, _):
                    if error != nil {
                        self.evalJS("window.__streamCallbacks['\(streamId)']?.onDone(-1); delete window.__streamCallbacks['\(streamId)']")
                    }
                }
            }
        }
    }

    // MARK: - JS 辅助

    /// 在 WKWebView 中执行 JS
    private func evalJS(_ script: String) {
        webView?.evaluateJavaScript(script, completionHandler: nil)
    }

    /// 将字符串安全转义为 JS 字符串字面量（含引号）
    /// 通过 JSON 数组序列化再提取，确保正确处理 \n \r \t ' " \ 等
    static func escapeForJS(_ text: String) -> String {
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
