//
//  BrowserWebView.swift
//  HLSMonitor
//

import SwiftUI
import WebKit
import Combine

@MainActor
final class BrowserViewModel: NSObject, ObservableObject {

    @Published var urlText: String = ""
    @Published private(set) var isLoading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false

    let monitor: HLSMonitorViewModel
    let webView: WKWebView

    private var observations: [NSKeyValueObservation] = []

    init(monitor: HLSMonitorViewModel) {
        self.monitor = monitor

        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let contentController = WKUserContentController()
        let script = WKUserScript(
            source: MonitorScripts.interception,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        contentController.addUserScript(script)
        configuration.userContentController = contentController

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.isScrollEnabled = true
        webView.scrollView.alwaysBounceVertical = true
        webView.scrollView.keyboardDismissMode = .interactive

        super.init()

        contentController.add(MessageProxy(handler: { [weak self] body in
            self?.monitor.handle(body)
        }), name: "hlsMonitor")

        webView.navigationDelegate = self

        observations = [
            webView.observe(\.estimatedProgress) { [weak self] view, _ in
                Task { @MainActor in self?.progress = view.estimatedProgress }
            },
            webView.observe(\.isLoading) { [weak self] view, _ in
                Task { @MainActor in self?.isLoading = view.isLoading }
            },
            webView.observe(\.canGoBack) { [weak self] view, _ in
                Task { @MainActor in self?.canGoBack = view.canGoBack }
            },
            webView.observe(\.canGoForward) { [weak self] view, _ in
                Task { @MainActor in self?.canGoForward = view.canGoForward }
            },
            webView.observe(\.url) { [weak self] view, _ in
                Task { @MainActor in
                    if let url = view.url { self?.urlText = url.absoluteString }
                }
            }
        ]
    }

    func submitURL() {
        var text = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Direct .m3u8 URLs get a tiny inline player page so monitoring works too.
        if !text.lowercased().hasPrefix("http") {
            if text.contains(".") && !text.contains(" ") {
                text = "https://" + text
            } else {
                text = "https://www.google.com/search?q=" +
                    (text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text)
            }
        }
        guard let url = URL(string: text) else { return }

        monitor.reset()
        if url.path.lowercased().hasSuffix(".m3u8") {
            loadInlinePlayer(for: url)
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    func reload() { webView.reload() }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    /// Kicks the web view's media pipeline back to life after the app returns
    /// from the background (e.g. the phone was locked while a stream played).
    /// WebKit suspends media decoding while backgrounded and doesn't always
    /// resume the `<video>` element automatically, leaving it stalled while
    /// segments keep downloading. Re-running the recovery routine re-primes it.
    func recoverPlaybackAfterForeground() {
        // Retry a couple of times: on the first tick WebKit may still be
        // resuming the media session, so an immediate nudge can be ignored.
        let delays: [TimeInterval] = [0.2, 0.8, 1.6]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak webView] in
                webView?.evaluateJavaScript(
                    "if (window.__hlsRecoverPlayback) { window.__hlsRecoverPlayback(); }",
                    completionHandler: nil
                )
            }
        }
    }

    private func loadInlinePlayer(for url: URL) {
        let html = """
        <!DOCTYPE html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>body{margin:0;background:#000;display:flex;align-items:center;justify-content:center;height:100vh}
        video{width:100%;max-height:100vh}</style></head>
        <body><video src="\(url.absoluteString)" controls autoplay playsinline></video></body></html>
        """
        webView.loadHTMLString(html, baseURL: url)
    }
}

extension BrowserViewModel: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Task { @MainActor in
            self.monitor.reset()
        }
    }
}

/// Avoids the WKUserContentController retain cycle on the view model.
private final class MessageProxy: NSObject, WKScriptMessageHandler {
    let handler: ([String: Any]) -> Void
    init(handler: @escaping ([String: Any]) -> Void) {
        self.handler = handler
    }
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        handler(body)
    }
}

struct BrowserWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
