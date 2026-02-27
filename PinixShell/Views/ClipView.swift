// ClipView.swift
// Clip 加载视图 — 配置 WKWebView + Scheme Handler + JSBridge，加载 pinix-web://clip-id/index.html

import SwiftUI
import WebKit

struct ClipView: View {
    let config: ClipConfig
    let initialFullscreen: Bool
    @State private var showShortcutGuide = false
    @State private var isFullscreen: Bool
    @State private var safeAreaInsets: UIEdgeInsets = .zero

    init(config: ClipConfig, initialFullscreen: Bool = false) {
        self.config = config
        self.initialFullscreen = initialFullscreen
        self._isFullscreen = State(initialValue: initialFullscreen)
    }

    var body: some View {
        ZStack {
            ClipWebView(config: config, safeAreaInsets: safeAreaInsets)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(isFullscreen ? .all : [])
            SafeAreaProbe { insets in
                if safeAreaInsets != insets {
                    safeAreaInsets = insets
                }
            }
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
        }
        .navigationTitle(config.alias)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(isFullscreen ? .hidden : .visible, for: .navigationBar, .bottomBar)
        .toolbar {
            if !isFullscreen {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            isFullscreen = true
                        }
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        UIPasteboard.general.string = "pinix://clip/\(config.alias)?fullscreen=1"
                        showShortcutGuide = true
                    } label: {
                        Image(systemName: "plus.app")
                    }
                }
            }
        }
        .navigationBarHidden(isFullscreen)
        .statusBarHidden(isFullscreen)
        .persistentSystemOverlays(isFullscreen ? .hidden : .automatic)
        .alert("链接已复制", isPresented: $showShortcutGuide) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("打开「快捷指令」App → 右上角 + 新建快捷指令 → 搜索并添加「打开 URL」动作 → 粘贴链接 → 完成后长按快捷指令 → 添加到主屏幕")
        }
    }
}

// MARK: - ClipWebView（UIViewRepresentable）

private struct ClipWebView: UIViewRepresentable {
    let config: ClipConfig
    var safeAreaInsets: UIEdgeInsets = .zero

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
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.contentInset = .zero
        webView.scrollView.scrollIndicatorInsets = .zero

        // 注入 Safe Area CSS 变量（首帧兜底，后续在 updateUIView 中刷新）
        let safeAreaScript = """
            (function() {
                var style = document.createElement('style');
                style.textContent = ':root { --sat: \(safeAreaInsets.top)px; --sab: \(safeAreaInsets.bottom)px; --sal: \(safeAreaInsets.left)px; --sar: \(safeAreaInsets.right)px; }';
                document.head ? document.head.appendChild(style) : document.documentElement.appendChild(style);
            })();
        """
        let userScript = WKUserScript(source: safeAreaScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        wkConfig.userContentController.addUserScript(userScript)

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
        context.coordinator.applySafeAreaInsets(safeAreaInsets, to: webView)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var bridge: JSBridge?
        private var lastInsets: UIEdgeInsets = .zero

        func applySafeAreaInsets(_ insets: UIEdgeInsets, to webView: WKWebView) {
            guard insets != lastInsets else { return }
            lastInsets = insets
            let js = """
                document.documentElement.style.setProperty('--sat', '\(insets.top)px');
                document.documentElement.style.setProperty('--sab', '\(insets.bottom)px');
                document.documentElement.style.setProperty('--sal', '\(insets.left)px');
                document.documentElement.style.setProperty('--sar', '\(insets.right)px');
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("[ClipView] 加载完成: \(webView.url?.absoluteString ?? "")")
            // 注入 safe area insets，确保 Web 端 env() 有正确数值
            if let windowInsets = webView.window?.safeAreaInsets {
                applySafeAreaInsets(windowInsets, to: webView)
                return
            }
            if let windowInsets = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows })
                .first(where: { $0.isKeyWindow })?.safeAreaInsets {
                applySafeAreaInsets(windowInsets, to: webView)
            }
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
            <html><head><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"></head><body style="background:#1a1a2e;color:#e94560;font-family:-apple-system,system-ui;padding:env(safe-area-inset-top,40px) 40px env(safe-area-inset-bottom,40px) 40px;display:flex;flex-direction:column;align-items:center;justify-content:center;min-height:100vh">
            <h2 style="margin-bottom:16px">加载失败</h2>
            <p style="font-size:14px;color:#aaa;max-width:80vw;word-break:break-all">\(escaped)</p>
            </body></html>
            """
            webView.loadHTMLString(html, baseURL: nil)
        }
    }
}

private struct SafeAreaProbe: UIViewRepresentable {
    var onChange: (UIEdgeInsets) -> Void

    func makeUIView(context: Context) -> SafeAreaProbeView {
        let view = SafeAreaProbeView()
        view.onChange = onChange
        return view
    }

    func updateUIView(_ uiView: SafeAreaProbeView, context: Context) {
        uiView.onChange = onChange
        uiView.reportIfNeeded()
    }
}

private final class SafeAreaProbeView: UIView {
    var onChange: ((UIEdgeInsets) -> Void)?
    private var lastInsets: UIEdgeInsets = .zero

    override func didMoveToWindow() {
        super.didMoveToWindow()
        reportIfNeeded()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        reportIfNeeded()
    }

    func reportIfNeeded() {
        guard let window = window else { return }
        let insets = window.safeAreaInsets
        guard insets != lastInsets else { return }
        lastInsets = insets
        onChange?(insets)
    }
}
