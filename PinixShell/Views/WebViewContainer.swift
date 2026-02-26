// WebViewContainer.swift
// WKWebView 的 SwiftUI 包装 — 接受外部 WKWebViewConfiguration

import SwiftUI
import WebKit

struct WebViewContainer: UIViewRepresentable {
    let url: URL?
    let configuration: WKWebViewConfiguration

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isInspectable = true

        if let url {
            webView.load(URLRequest(url: url))
        }

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard let url else { return }
        if webView.url != url {
            webView.load(URLRequest(url: url))
        }
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("[PinixShell] 加载完成: \(webView.url?.absoluteString ?? "")")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            print("[PinixShell] 导航失败: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("[PinixShell] 加载失败: \(error.localizedDescription)")
        }
    }
}
