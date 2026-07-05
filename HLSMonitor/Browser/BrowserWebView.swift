//
//  BrowserWebView.swift
//  HLSMonitor
//

import SwiftUI
import WebKit
import Combine

@MainActor
final class BrowserViewModel: NSObject, ObservableObject {

    /// Known-good HLS streams offered on the launch screen and in the
    /// bookmark menu, verified down to segment delivery.
    static let suggestedStreams: [(name: String, url: String)] = [
        ("Mux Live Test", "https://stream.mux.com/v69RSHhFelSm4701snP22dYz2jICy4E4FUyk02rW4gxRM.m3u8"),
        ("Unified Streaming", "https://demo.unified-streaming.com/k8s/live/stable/scte35.isml/.m3u8"),
        ("NASA+ (VOD)", "https://nasaplus.akamaized.net/output/16899.m3u8"),
    ]

    @Published var urlText: String = ""
    @Published private(set) var isLoading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false

    /// Whether "remember this URL" is enabled. When on, the last submitted URL
    /// is persisted and restored on the next launch.
    @Published var rememberURL: Bool {
        didSet {
            UserDefaults.standard.set(rememberURL, forKey: Self.rememberFlagKey)
            if rememberURL {
                persistCurrentURL()
            } else {
                UserDefaults.standard.removeObject(forKey: Self.savedURLKey)
            }
        }
    }

    /// The most recently saved livestream URL, if any.
    @Published private(set) var savedURL: String?

    /// Whether the web view has been asked to load any content yet. Used to show
    /// a friendly placeholder instead of a bare black web view on first launch.
    @Published private(set) var hasContent = false

    let monitor: HLSMonitorViewModel
    let webView: WKWebView

    private var observations: [NSKeyValueObservation] = []

    private static let savedURLKey = "HLSMonitor.savedURL"
    private static let rememberFlagKey = "HLSMonitor.rememberURL"

    init(monitor: HLSMonitorViewModel) {
        self.monitor = monitor

        let defaults = UserDefaults.standard
        // Default to remembering so a returning user's stream is right there.
        let remember = defaults.object(forKey: Self.rememberFlagKey) as? Bool ?? true
        self.rememberURL = remember
        self.savedURL = defaults.string(forKey: Self.savedURLKey)

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
        // Avoid an opaque black web view when there is no page content yet.
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear

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

        // Pre-fill the address bar with the remembered URL but don't load it:
        // the launch screen offers the saved stream and the test streams as
        // choices instead of auto-opening anything.
        if rememberURL, let saved = savedURL, !saved.isEmpty {
            urlText = saved
        }
    }

    /// Loads a stream picked from the launch screen or the bookmark menu.
    func loadStream(_ urlString: String) {
        urlText = urlString
        load(urlString: urlString)
    }

    func submitURL() {
        let text = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        load(urlString: text)
    }

    /// Normalizes a raw string into a URL, loads it, and persists it when
    /// "remember URL" is enabled.
    private func load(urlString: String) {
        var text = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
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

        if rememberURL {
            saveURL(text)
        }

        monitor.reset()
        hasContent = true
        if url.path.lowercased().hasSuffix(".m3u8") {
            loadInlinePlayer(for: url)
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    private func saveURL(_ urlString: String) {
        savedURL = urlString
        UserDefaults.standard.set(urlString, forKey: Self.savedURLKey)
    }

    private func persistCurrentURL() {
        let text = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        saveURL(text)
    }

    /// Forgets the saved livestream URL so it won't be restored next launch.
    func clearSavedURL() {
        savedURL = nil
        UserDefaults.standard.removeObject(forKey: Self.savedURLKey)
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

    /// Wraps a raw .m3u8 URL in a minimal player page. hls.js drives playback
    /// when Media Source Extensions are available: it reliably refreshes live
    /// playlists (the built-in WKWebView HLS engine can stall at the end of the
    /// initial window) and issues manifest/segment requests through fetch/XHR,
    /// which the injected monitor script intercepts directly. Falls back to the
    /// native engine when hls.js can't load or can't play the stream.
    private func loadInlinePlayer(for url: URL) {
        let html = """
        <!DOCTYPE html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>body{margin:0;background:#000;display:flex;align-items:center;justify-content:center;height:100vh}
        video{width:100%;max-height:100vh}</style>
        <script src="https://cdn.jsdelivr.net/npm/hls.js@1.6.16/dist/hls.min.js"></script>
        </head>
        <body><video id="player" controls autoplay playsinline></video>
        <script>
        (function() {
            var video = document.getElementById('player');
            var src = "\(url.absoluteString)";
            function playNatively() { video.src = src; }
            if (window.Hls && Hls.isSupported()) {
                var hls = new Hls({ liveDurationInfinity: true });
                hls.on(Hls.Events.ERROR, function(_, data) {
                    if (!data.fatal) { return; }
                    if (data.type === Hls.ErrorTypes.MEDIA_ERROR) {
                        hls.recoverMediaError();
                        return;
                    }
                    if (data.type === Hls.ErrorTypes.NETWORK_ERROR &&
                        data.details !== Hls.ErrorDetails.MANIFEST_LOAD_ERROR) {
                        hls.startLoad();
                        return;
                    }
                    // Manifest unreadable from JS (e.g. no CORS) or an
                    // unrecoverable error: let the native engine try.
                    hls.destroy();
                    playNatively();
                });
                // Feed remuxed audio segments to the injected loudness meter:
                // WebKit gives the page no PCM access to <video> audio, so
                // LUFS is measured from the stream content instead.
                hls.on(Hls.Events.BUFFER_APPENDING, function(_, data) {
                    if (data.type !== 'audio' || !data.data) { return; }
                    if (data.frag && data.frag.sn === 'initSegment') {
                        if (window.__hlsMonitorAudioInit) { window.__hlsMonitorAudioInit(data.data); }
                    } else if (window.__hlsMonitorAudioChunk) {
                        window.__hlsMonitorAudioChunk(data.data);
                    }
                });
                hls.loadSource(src);
                hls.attachMedia(video);
            } else {
                playNatively();
            }
        })();
        </script></body></html>
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
