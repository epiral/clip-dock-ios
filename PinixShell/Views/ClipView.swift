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
    @State private var webViewReloader = WebViewReloader()

    init(config: ClipConfig, initialFullscreen: Bool = false) {
        self.config = config
        self.initialFullscreen = initialFullscreen
        self._isFullscreen = State(initialValue: initialFullscreen)
    }

    var body: some View {
        ZStack {
            ClipWebView(config: config, safeAreaInsets: safeAreaInsets, isFullscreen: isFullscreen, reloader: webViewReloader)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            SafeAreaProbe { insets in
                if safeAreaInsets != insets {
                    safeAreaInsets = insets
                }
            }
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
        }
        .background(Color(red: 0.1, green: 0.1, blue: 0.18))
        .ignoresSafeArea(isFullscreen ? .all : [])
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
                        DiskCache.shared.clearWebCache(alias: config.alias)
                        webViewReloader.reload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
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
        .persistentSystemOverlays(isFullscreen ? .hidden : .automatic)
        .alert("链接已复制", isPresented: $showShortcutGuide) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("打开「快捷指令」App → 右上角 + 新建快捷指令 → 搜索并添加「打开 URL」动作 → 粘贴链接 → 完成后长按快捷指令 → 添加到主屏幕")
        }
    }
}

// MARK: - ClipWebViewContainer（UIKit 容器，全屏模式下通过 additionalSafeAreaInsets 让 WKWebView 铺满全屏）

private final class ClipWebViewContainer: UIView {
    let webView: WKWebView
    var extendToEdges = false {
        didSet { if extendToEdges != oldValue { negateHostingSafeArea() } }
    }

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        addSubview(webView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        webView.frame = bounds
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        negateHostingSafeArea()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        negateHostingSafeArea()
    }

    /// 全屏模式：将 hosting controller 的 additionalSafeAreaInsets 设为窗口 insets 的负值，
    /// 使 SwiftUI 布局认为 Safe Area 为零，WKWebView 可铺满整个屏幕
    private func negateHostingSafeArea() {
        guard let vc = findViewController() else { return }
        if extendToEdges, let window = window {
            let insets = window.safeAreaInsets
            let needed = UIEdgeInsets(
                top: -insets.top, left: -insets.left,
                bottom: -insets.bottom, right: -insets.right
            )
            if vc.additionalSafeAreaInsets != needed {
                vc.additionalSafeAreaInsets = needed
            }
        } else {
            if vc.additionalSafeAreaInsets != .zero {
                vc.additionalSafeAreaInsets = .zero
            }
        }
    }

    private func findViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let r = responder?.next {
            if let vc = r as? UIViewController { return vc }
            responder = r
        }
        return nil
    }
}

// MARK: - ClipWebView（UIViewRepresentable）

/// WebView 刷新桥接：ClipView 按钮 → ClipWebView Coordinator
@Observable
final class WebViewReloader {
    fileprivate weak var webView: WKWebView?

    func reload() {
        webView?.reload()
    }
}

private struct ClipWebView: UIViewRepresentable {
    let config: ClipConfig
    var safeAreaInsets: UIEdgeInsets = .zero
    var isFullscreen: Bool = false
    var reloader: WebViewReloader

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> ClipWebViewContainer {
        let wkConfig = WKWebViewConfiguration()

        // 注册 pinix-web:// scheme handler（web 资源，带磁盘缓存）
        let webHandler = PinixWebSchemeHandler(host: config.baseURL, token: config.token, alias: config.alias)
        wkConfig.setURLSchemeHandler(webHandler, forURLScheme: "pinix-web")

        // 注册 pinix-data:// scheme handler（数据文件，ETag 协商缓存，支持 Range）
        let dataHandler = PinixDataSchemeHandler(host: config.baseURL, token: config.token, alias: config.alias)
        wkConfig.setURLSchemeHandler(dataHandler, forURLScheme: "pinix-data")

        // 注册 JSBridge
        let bridge = JSBridge(pinixHost: config.baseURL, pinixToken: config.token)
        JSBridge.register(to: wkConfig.userContentController, bridge: bridge)
        context.coordinator.bridge = bridge

        let webView = WKWebView(frame: .zero, configuration: wkConfig)
        bridge.setWebView(webView)
        webView.navigationDelegate = context.coordinator
        webView.isInspectable = true
        reloader.webView = webView
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.18, alpha: 1)
        webView.scrollView.backgroundColor = webView.backgroundColor
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.contentInset = .zero
        webView.scrollView.scrollIndicatorInsets = .zero

        // 注入 viewport-fit=cover + Safe Area CSS 变量 + env() 兜底覆盖
        // 因为 additionalSafeAreaInsets 取反让 WKWebView 铺满全屏，env(safe-area-inset-*) 返回 0，
        // 所以需要用 CSS 覆盖将 env() 用法替换为 var(--sab) 等自定义属性
        let bootstrapScript = """
            (function() {
                // 确保 viewport-fit=cover，让 web 内容填满全屏
                var meta = document.querySelector('meta[name="viewport"]');
                if (meta) {
                    if (meta.content.indexOf('viewport-fit') === -1) {
                        meta.content += ', viewport-fit=cover';
                    }
                } else {
                    meta = document.createElement('meta');
                    meta.name = 'viewport';
                    meta.content = 'width=device-width, initial-scale=1, viewport-fit=cover';
                    (document.head || document.documentElement).appendChild(meta);
                }
                // Safe Area CSS 变量 + 覆盖常见 env() 用法
                var style = document.createElement('style');
                style.id = 'pinix-safe-area';
                style.textContent = ':root { --sat: \(safeAreaInsets.top)px; --sab: \(safeAreaInsets.bottom)px; --sal: \(safeAreaInsets.left)px; --sar: \(safeAreaInsets.right)px; }' +
                    '.tab-bar { padding-bottom: max(6px, var(--sab, 0px)) !important; }' +
                    '.detail-panel { padding-bottom: max(16px, var(--sab, 0px)) !important; }';
                (document.head || document.documentElement).appendChild(style);
            })();
        """
        let userScript = WKUserScript(source: bootstrapScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        wkConfig.userContentController.addUserScript(userScript)

        // 加载 Clip 入口（clipId 使用 alias）
        let safeAlias = config.alias.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? config.alias
        guard let entryURL = URL(string: "pinix-web://\(safeAlias)/web/index.html") else {
            print("[ClipView] 无效 URL，alias: \(config.alias)")
            let container = ClipWebViewContainer(webView: webView)
            container.extendToEdges = isFullscreen
            return container
        }
        webView.load(URLRequest(url: entryURL))

        let container = ClipWebViewContainer(webView: webView)
        container.extendToEdges = isFullscreen
        return container
    }

    func updateUIView(_ container: ClipWebViewContainer, context: Context) {
        container.extendToEdges = isFullscreen
        container.setNeedsLayout()
        context.coordinator.applySafeAreaInsets(safeAreaInsets, to: container.webView)
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
                // 直接修补使用 env() 的元素，因为 additionalSafeAreaInsets 取反后 env() 返回 0
                document.querySelectorAll('.tab-bar').forEach(function(el) {
                    el.style.paddingBottom = Math.max(6, \(insets.bottom)) + 'px';
                });
                document.querySelectorAll('.detail-panel').forEach(function(el) {
                    el.style.paddingBottom = Math.max(16, \(insets.bottom)) + 'px';
                });
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("[ClipView] 加载完成: \(webView.url?.absoluteString ?? "")")
            // 页面加载完毕，强制重新注入 CSS 变量（防止 updateUIView 在页面未就绪时注入失败）
            lastInsets = .zero
            if let windowInsets = webView.window?.safeAreaInsets {
                applySafeAreaInsets(windowInsets, to: webView)
            } else if let windowInsets = UIApplication.shared.connectedScenes
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

// MARK: - SafeAreaProbe（UIKit 探针，获取真实 Safe Area Insets）

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
