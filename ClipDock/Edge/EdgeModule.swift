import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import SwiftUI
import Observation

// MARK: - Environment Key

private struct EdgeModuleKey: EnvironmentKey {
    @MainActor static let defaultValue = EdgeModule()
}

extension EnvironmentValues {
    var edgeModule: EdgeModule {
        get { self[EdgeModuleKey.self] }
        set { self[EdgeModuleKey.self] = newValue }
    }
}

// MARK: - Log Entry

struct EdgeLogEntry: Identifiable {
    let id = UUID()
    let time: Date
    let message: String
}

// MARK: - EdgeModule

@MainActor
@Observable
final class EdgeModule {

    enum Status: String {
        case idle = "未启动"
        case connecting = "连接中..."
        case connected = "已连接"
        case reconnecting = "重连中..."
        case error = "错误"
        case disabled = "未启用"
    }

    private(set) var status: Status = .idle
    private(set) var clipID: String = ""
    private(set) var clipToken: String = ""
    var logs: [EdgeLogEntry] = []

    private var connectionTask: Task<Void, Never>?
    private var isRunning = false
    private let router = EdgeCommandRouter()

    // MARK: - Logging

    func log(_ msg: String) {
        let entry = EdgeLogEntry(time: Date(), message: msg)
        logs.append(entry)
        if logs.count > 200 { logs.removeFirst(logs.count - 200) }
        print("[Edge] \(msg)")
    }

    // MARK: - Lifecycle

    func start() {
        let config = EdgeConfig.load()
        guard config.enabled else {
            status = .disabled
            log("未启用")
            return
        }
        guard !config.serverURL.isEmpty, !config.superToken.isEmpty else {
            status = .error
            log("缺少 Server URL 或 Super Token")
            return
        }
        guard !isRunning else {
            log("已在运行")
            return
        }

        isRunning = true
        status = .connecting
        log("启动: server=\(config.serverURL)")

        connectionTask = Task { [weak self] in
            await self?.connectionLoop(config: config)
        }
    }

    func stop() {
        isRunning = false
        connectionTask?.cancel()
        connectionTask = nil
        status = .idle
        clipID = ""
        clipToken = ""
        log("已停止")
    }

    func restart() {
        stop()
        start()
    }

    // MARK: - Connection Loop

    private func connectionLoop(config: EdgeConfig) async {
        var backoff: UInt64 = 1
        let maxBackoff: UInt64 = 60

        while isRunning && !Task.isCancelled {
            do {
                status = backoff > 1 ? .reconnecting : .connecting
                try await connectOnce(config: config)
                backoff = 1
            } catch {
                if Task.isCancelled { break }
                status = .error
                log("连接失败: \(error.localizedDescription)")
                log("将在 \(backoff)s 后重连...")
            }

            if !isRunning || Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
            backoff = min(backoff * 2, maxBackoff)
        }

        status = .idle
        log("连接循环退出")
    }

    // MARK: - Single Connection

    private func connectOnce(config: EdgeConfig) async throws {
        let (hostname, port) = try ClipDockBridgeHandler.parseHost(config.serverURL)
        log("正在连接 \(hostname):\(port)...")

        var metadata: Metadata = [:]
        metadata.addString("Bearer \(config.superToken)", forKey: "authorization")

        let (outboundStream, outboundContinuation) = AsyncStream<Pinix_V1_EdgeUpstream>.makeStream()
        let router = self.router

        try await withGRPCClient(
            transport: .http2NIOPosix(
                target: .dns(host: hostname, port: port),
                transportSecurity: .plaintext
            )
        ) { (client) -> Void in
            let edgeService = Pinix_V1_EdgeService.Client(wrapping: client)

            try await edgeService.connect(
                metadata: metadata,
                requestProducer: { writer in
                    let manifest = Self.buildManifest()
                    var upstream = Pinix_V1_EdgeUpstream()
                    upstream.msg = .manifest(manifest)
                    try await writer.write(upstream)
                    await MainActor.run { self.log("Manifest 已发送 (\(manifest.commands.count) 命令)") }

                    for await msg in outboundStream {
                        if Task.isCancelled { break }
                        try await writer.write(msg)
                    }
                },
                onResponse: { response in
                    for try await downstream in response.messages {
                        if Task.isCancelled { break }

                        switch downstream.msg {
                        case .accepted(let accepted):
                            await MainActor.run {
                                self.clipID = accepted.clipID
                                self.clipToken = accepted.token
                                self.status = .connected
                                self.log("注册成功! clipID=\(accepted.clipID)")
                            }

                        case .request(let edgeRequest):
                            let cont = outboundContinuation
                            Task { @MainActor in
                                self.log("收到请求: \(edgeRequest.requestID)")
                                await Self.handleRequest(edgeRequest, router: router, outbound: cont)
                                self.log("请求完成: \(edgeRequest.requestID)")
                            }

                        case .pong:
                            break

                        case .rejected(let rejected):
                            await MainActor.run {
                                self.status = .error
                                self.log("被拒绝: \(rejected.reason)")
                            }
                            outboundContinuation.finish()
                            return

                        case nil:
                            break
                        }
                    }
                    outboundContinuation.finish()
                    await MainActor.run {
                        self.status = .reconnecting
                        self.log("服务端断开连接")
                    }
                }
            )
        }
    }

    // MARK: - Handle Request

    @MainActor
    private static func handleRequest(
        _ request: Pinix_V1_EdgeRequest,
        router: EdgeCommandRouter,
        outbound: AsyncStream<Pinix_V1_EdgeUpstream>.Continuation
    ) async {
        let rid = request.requestID

        func send(_ resp: Pinix_V1_EdgeResponse) {
            var upstream = Pinix_V1_EdgeUpstream()
            upstream.msg = .response(resp)
            outbound.yield(upstream)
        }

        switch request.body {
        case .invoke(let invoke):
            let (stdout, exitCode) = await router.execute(name: invoke.name, args: invoke.args, stdin: invoke.stdin)

            var r1 = Pinix_V1_EdgeResponse()
            r1.requestID = rid
            r1.body = .invokeChunk(Pinix_V1_InvokeChunk.with { $0.payload = .stdout(stdout) })
            send(r1)

            var r2 = Pinix_V1_EdgeResponse()
            r2.requestID = rid
            r2.body = .invokeChunk(Pinix_V1_InvokeChunk.with { $0.payload = .exitCode(exitCode) })
            send(r2)

            var r3 = Pinix_V1_EdgeResponse()
            r3.requestID = rid
            r3.body = .complete(Pinix_V1_EdgeComplete())
            send(r3)

        case .getInfo:
            var resp = Pinix_V1_EdgeResponse()
            resp.requestID = rid
            resp.body = .getInfo(Pinix_V1_GetInfoResponse.with {
                $0.name = "clip-dock-ios"
                $0.description_p = "iOS Edge Clip"
                $0.commands = EdgeCommandRouter.commandDefs.map { $0.name }
                $0.hasWeb_p = false
            })
            send(resp)

        case .cancel:
            var resp = Pinix_V1_EdgeResponse()
            resp.requestID = rid
            resp.body = .complete(Pinix_V1_EdgeComplete())
            send(resp)

        default:
            var resp = Pinix_V1_EdgeResponse()
            resp.requestID = rid
            resp.body = .error(Pinix_V1_EdgeError.with { $0.message = "unsupported request" })
            send(resp)
        }
    }

    // MARK: - Build Manifest

    private nonisolated static func buildManifest() -> Pinix_V1_EdgeManifest {
        var manifest = Pinix_V1_EdgeManifest()
        manifest.name = "clip-dock-ios"
        manifest.description_p = "iOS Edge Clip"
        manifest.hasWeb_p = false
        manifest.commands = EdgeCommandRouter.commandDefs.map { def in
            var cmd = Pinix_V1_EdgeCommandDef()
            cmd.name = def.name
            cmd.description_p = def.description
            return cmd
        }
        return manifest
    }
}
