// PinixBridgeHandler.swift
// Pinix Connect-RPC Bridge — 将 JS Bridge.invoke(action, payload) 映射到 ClipService.Invoke RPC
//
// Depends: Connect, PinixClient (gen), JSBridge
// Exports: PinixBridgeHandler

import Foundation
import Connect

@MainActor
final class PinixBridgeHandler {

    static let actions: Set<String> = ["invoke"]

    /// 由 JSBridge 从配置注入，禁止 JS 层传入
    private var host: String
    private var token: String

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
                networkProtocol: .connect,
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
        default:
            replyHandler(nil, "PinixBridgeHandler: unknown action \(action)")
        }
    }

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
            let response = await client.invoke(request: request, headers: headers)
            if let msg = response.message {
                let result: [String: Any] = [
                    "stdout": msg.stdout,
                    "stderr": msg.stderr,
                    "exitCode": Int(msg.exitCode)
                ]
                replyHandler(result, nil)
            } else if let error = response.error {
                replyHandler(nil, "invoke error: \(error.message ?? error.localizedDescription)")
            } else {
                replyHandler(nil, "invoke: unexpected empty response")
            }
        }
    }
}
