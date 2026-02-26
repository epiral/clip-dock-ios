// JSBridge.swift
// 路由分发器 — 将 JS 消息分派到 PinixBridgeHandler
//
// Clip JS 看到的接口：
//   fetch("pinix-web://clip-id/app.js")       → Scheme 拦截 → ReadFile
//   fetch("pinix-data://clip-id/voice.mp3")    → Scheme 拦截 → ReadFile（支持 Range）
//   Bridge.invoke("createNote", { title: "Hello" })  → Bridge → ClipService.Invoke

import Foundation
import WebKit

@MainActor
final class JSBridge: NSObject, WKScriptMessageHandlerWithReply {

    private let pinixHandler: PinixBridgeHandler

    // MARK: - Init

    init(pinixHost: String = "", pinixToken: String = "") {
        self.pinixHandler = PinixBridgeHandler(host: pinixHost, token: pinixToken)
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

        if action == "consoleLog" {
            let level = body["level"] as? String ?? "log"
            let msg = body["message"] as? String ?? ""
            print("[JS:\(level)] \(msg)")
            replyHandler("ok", nil)
        } else if PinixBridgeHandler.actions.contains(action) {
            pinixHandler.handle(action: action, body: body, replyHandler: replyHandler)
        } else {
            replyHandler(nil, "Unknown action: \(action)")
        }
    }

    // MARK: - 注入的辅助 JS

    /// Bridge.invoke(action, payload) — 唯一写操作入口
    private static let bridgeHelperJS = """
    window.Bridge = {
        async invoke(action) {
            var payload = {};
            if (arguments.length > 1 && typeof arguments[1] === 'object') {
                payload = arguments[1];
            }
            return await window.webkit.messageHandlers.pinix.postMessage({
                action: "invoke",
                name: action,
                args: payload.args || [],
                stdin: payload.stdin || ""
            });
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
