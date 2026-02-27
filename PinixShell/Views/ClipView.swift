// ClipView.swift
// Clip 加载视图 — 配置 WKWebView + Scheme Handler + JSBridge，加载 pinix-web://clip-id/index.html

import SwiftUI
import WebKit

struct ClipView: View {
    let config: ClipConfig

    var body: some View {
        ClipWebView(config: config)
            .navigationTitle(config.alias)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        addToHomeScreen(clip: config)
                    } label: {
                        Image(systemName: "plus.app")
                    }
                }
            }
    }

    private func addToHomeScreen(clip: ClipConfig) {
        let shortcutData = generateShortcutFile(alias: clip.alias, displayName: clip.alias)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(clip.alias).shortcut")
        try? shortcutData.write(to: tempURL)

        let activityVC = UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            // Walk to the topmost presented controller
            var topVC = rootVC
            while let presented = topVC.presentedViewController {
                topVC = presented
            }
            activityVC.popoverPresentationController?.barButtonItem = nil
            topVC.present(activityVC, animated: true)
        }
    }

    private func generateShortcutFile(alias: String, displayName: String) -> Data {
        let dict: [String: Any] = [
            "WFWorkflowMinimumClientVersionString": "900",
            "WFWorkflowMinimumClientVersion": 900,
            "WFWorkflowClientVersion": "2.3",
            "WFWorkflowIcon": [
                "WFWorkflowIconStartColor": 431817727,
                "WFWorkflowIconGlyphNumber": 59511
            ],
            "WFWorkflowInputContentItemClasses": [] as [String],
            "WFWorkflowActions": [
                [
                    "WFWorkflowActionIdentifier": "is.workflow.actions.openurl",
                    "WFWorkflowActionParameters": [
                        "WFURLActionURL": "pinix://clip/\(alias)"
                    ]
                ]
            ],
            "WFWorkflowName": displayName,
            "WFWorkflowHasShortcutInputVariables": false
        ]
        return try! PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }
}

// MARK: - ClipWebView（UIViewRepresentable）

private struct ClipWebView: UIViewRepresentable {
    let config: ClipConfig

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let wkConfig = WKWebViewConfiguration()

        // 注册 pinix-web:// scheme handler（web 资源）
        let webHandler = PinixWebSchemeHandler(host: config.baseURL, token: config.token)
        wkConfig.setURLSchemeHandler(webHandler, forURLScheme: "pinix-web")

        // 注册 pinix-data:// scheme handler（数据文件，支持 Range）
        let dataHandler = PinixDataSchemeHandler(host: config.baseURL, token: config.token)
        wkConfig.setURLSchemeHandler(dataHandler, forURLScheme: "pinix-data")

        // 注册 JSBridge
        let bridge = JSBridge(pinixHost: config.baseURL, pinixToken: config.token)
        JSBridge.register(to: wkConfig.userContentController, bridge: bridge)
        context.coordinator.bridge = bridge

        let webView = WKWebView(frame: .zero, configuration: wkConfig)
        webView.navigationDelegate = context.coordinator
        webView.isInspectable = true
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.18, alpha: 1)
        webView.scrollView.backgroundColor = webView.backgroundColor

        // 加载 Clip 入口（clipId 使用 alias）
        let safeAlias = config.alias.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? config.alias
        guard let entryURL = URL(string: "pinix-web://\(safeAlias)/web/index.html") else {
            print("[ClipView] 无效 URL，alias: \(config.alias)")
            return webView
        }
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
