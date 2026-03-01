// JSBridge.swift
// 路由分发器 — 将 JS 消息分派到对应 Handler
//
// JS 调用方式：
//   Bridge.invoke("invoke", { name, args, stdin })    → ClipDockBridgeHandler  (Pinix RPC，累积模式)
//   Bridge.invokeStream(command, opts, onChunk, onDone) → ClipDockBridgeHandler  (Pinix RPC，流式)
//   Bridge.invoke("ios.clipboardRead")                → IOSSystemBridgeHandler
//   Bridge.invoke("ios.haptic", { style: "medium" })  → IOSSystemBridgeHandler
//   Bridge.invoke("ios.locationGet")                  → IOSLocationBridgeHandler
//   Bridge.invoke("ios.cameraCapture")                → IOSMediaBridgeHandler
//   Bridge.invoke("ios.microphoneRecord", { maxSeconds: 30 }) → IOSMediaBridgeHandler
//   Bridge.invoke("ios.speakingStart", { apiKey, topic? })   → SpeakingSessionHandler
//   Bridge.invoke("ios.speakingStop")                        → SpeakingSessionHandler
//   Bridge.invoke("ios.speakingStatus")                      → SpeakingSessionHandler
//
// 命名规约：
//   "invoke"        — 通用 Pinix RPC 入口（累积），无平台前缀
//   "invokeStream"  — 流式 Pinix RPC 入口，通过 streamId 回调 JS
//   "ios.*"         — iOS 平台专属能力

import Foundation
import WebKit

@MainActor
final class JSBridge: NSObject, WKScriptMessageHandlerWithReply {

    private let pinixHandler:   ClipDockBridgeHandler
    private let iosSystem:      IOSSystemBridgeHandler
    private let iosLocation:    IOSLocationBridgeHandler
    private let iosMedia:       IOSMediaBridgeHandler
    private let iosHealth:      IOSHealthBridgeHandler
    private let iosSpeaking:    SpeakingSessionHandler

    // MARK: - Init

    init(pinixHost: String = "", pinixToken: String = "") {
        self.pinixHandler  = ClipDockBridgeHandler(host: pinixHost, token: pinixToken)
        self.iosSystem     = IOSSystemBridgeHandler()
        self.iosLocation   = IOSLocationBridgeHandler()
        self.iosMedia      = IOSMediaBridgeHandler()
        self.iosHealth     = IOSHealthBridgeHandler()
        self.iosSpeaking   = SpeakingSessionHandler()
        super.init()
    }

    // MARK: - 注册到 WKWebView

    static func register(to controller: WKUserContentController, bridge: JSBridge) {
        controller.addScriptMessageHandler(bridge, contentWorld: .page, name: "pinix")

        // 注入 Bridge JS：提供 window.Bridge.invoke()
        let bridgeScript = WKUserScript(
            source: Self.bridgeHelperJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page
        )
        controller.addUserScript(bridgeScript)

        // 注入 console 拦截脚本
        let consoleScript = WKUserScript(
            source: Self.consoleInterceptJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page
        )
        controller.addUserScript(consoleScript)
    }

    /// 更新 Pinix 连接配置（当 Clip 切换时调用）
    func updatePinixConfig(host: String, token: String) {
        pinixHandler.updateConfig(host: host, token: token)
    }

    /// 绑定 WKWebView 引用（用于 streaming 回调和 SpeakingSessionHandler 推送事件到 JS）
    func setWebView(_ webView: WKWebView) {
        pinixHandler.webView = webView
        iosSpeaking.webView = webView
    }

    // MARK: - WKScriptMessageHandlerWithReply

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String else {
            replyHandler(nil, "Invalid message format: missing 'action'")
            return
        }

        // console 拦截（内部消息，不走 Bridge 路由）
        if action == "consoleLog" {
            let level = body["level"] as? String ?? "log"
            let msg = body["message"] as? String ?? ""
            print("[JS:\(level)] \(msg)")
            replyHandler("ok", nil)
            return
        }

        // 路由分发
        if ClipDockBridgeHandler.actions.contains(action) {
            pinixHandler.handle(action: action, body: body, replyHandler: replyHandler)
        } else if IOSSystemBridgeHandler.actions.contains(action) {
            iosSystem.handle(action: action, body: body, replyHandler: replyHandler)
        } else if IOSLocationBridgeHandler.actions.contains(action) {
            iosLocation.handle(action: action, body: body, replyHandler: replyHandler)
        } else if IOSMediaBridgeHandler.actions.contains(action) {
            iosMedia.handle(action: action, body: body, replyHandler: replyHandler)
        } else if IOSHealthBridgeHandler.actions.contains(action) {
            iosHealth.handle(action: action, body: body, replyHandler: replyHandler)
        } else if SpeakingSessionHandler.actions.contains(action) {
            iosSpeaking.handle(action: action, body: body, replyHandler: replyHandler)
        } else {
            replyHandler(nil, "Unknown action: \(action)")
        }
    }

    // MARK: - 注入的辅助 JS

    /// Bridge.invoke(action, payload?)  — 单次 RPC，返回 Promise
    /// Bridge.invokeStream(command, opts, onChunk, onDone) — 流式 RPC，回调模式
    private static let bridgeHelperJS = """
    window.__streamCallbacks = {};
    window.Bridge = {
        async invoke(action, payload) {
            var body = { action: action };
            if (payload && typeof payload === 'object') {
                Object.assign(body, payload);
            }
            return await window.webkit.messageHandlers.pinix.postMessage(body);
        },
        invokeStream: function(command, opts, onChunk, onDone) {
            var streamId = 'stream_' + Date.now() + '_' + Math.random().toString(36).substr(2,9);
            window.__streamCallbacks[streamId] = { onChunk: onChunk, onDone: onDone };
            window.webkit.messageHandlers.pinix.postMessage({
                action: 'invokeStream',
                command: command,
                streamId: streamId,
                args: (opts && opts.args) || [],
                stdin: (opts && opts.stdin) || ''
            });
            return streamId;
        }
    };
    """

    // MARK: - Console 拦截 JS

    private static let consoleInterceptJS = """
    (function() {
        function _send(level, args) {
            var msg = Array.prototype.slice.call(args).map(function(a) {
                try { return typeof a === 'object' ? JSON.stringify(a) : String(a); }
                catch(e) { return String(a); }
            }).join(' ');
            try {
                window.webkit.messageHandlers.pinix.postMessage({
                    action: 'consoleLog', level: level, message: msg
                });
            } catch(e) {}
        }
        var _log = console.log, _warn = console.warn, _error = console.error;
        console.log   = function() { _send('log',   arguments); _log.apply(console, arguments); };
        console.warn  = function() { _send('warn',  arguments); _warn.apply(console, arguments); };
        console.error = function() { _send('error', arguments); _error.apply(console, arguments); };
    })();
    """
}
