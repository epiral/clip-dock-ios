// ClipView.swift
// Clip 加载视图 — 配置 WKWebView + Scheme Handler + JSBridge，加载 pinix-web://clip-id/index.html

import SwiftUI
import WebKit

struct ClipView: View {
    let clipId: String
    let host: String
    let token: String

    var body: some View {
        ClipWebView(clipId: clipId, host: host, token: token)
            .edgesIgnoringSafeArea(.all)
    }
}

// MARK: - ClipWebView（UIViewRepresentable）

private struct ClipWebView: UIViewRepresentable {
    let clipId: String
    let host: String
    let token: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()

        // 注册 pinix-web:// scheme handler（web 资源）
        let webHandler = PinixWebSchemeHandler(host: host, token: token)
        config.setURLSchemeHandler(webHandler, forURLScheme: "pinix-web")

        // 注册 pinix-data:// scheme handler（数据文件，支持 Range）
        let dataHandler = PinixDataSchemeHandler(host: host, token: token)
        config.setURLSchemeHandler(dataHandler, forURLScheme: "pinix-data")

        // 注册 JSBridge
        let bridge = JSBridge(pinixHost: host, pinixToken: token)
        JSBridge.register(to: config.userContentController, bridge: bridge)
        context.coordinator.bridge = bridge

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.isInspectable = true

        // 加载 Clip 入口
        let entryURL = URL(string: "pinix-web://\(clipId)/index.html")!
        webView.load(URLRequest(url: entryURL))

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Clip 配置变更时可在此更新
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var bridge: JSBridge?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("[ClipView] 加载完成: \(webView.url?.absoluteString ?? "")")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            print("[ClipView] 导航失败: \(error.localizedDescription)")
            showError(in: webView, error: error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("[ClipView] 加载失败: \(error.localizedDescription)")
            showError(in: webView, error: error)
        }

        private func showError(in webView: WKWebView, error: Error) {
            let escaped = error.localizedDescription
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
            let html = """
            <html><body style="background:#1a1a2e;color:#e94560;font-family:-apple-system,system-ui;padding:40px;display:flex;flex-direction:column;align-items:center;justify-content:center;min-height:100vh">
            <h2 style="margin-bottom:16px">加载失败</h2>
            <p style="font-size:14px;color:#aaa;max-width:80vw;word-break:break-all">\(escaped)</p>
            </body></html>
            """
            webView.loadHTMLString(html, baseURL: nil)
        }
    }
}
