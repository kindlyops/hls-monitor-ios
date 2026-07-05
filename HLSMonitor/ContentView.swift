//
//  ContentView.swift
//  HLSMonitor
//
//  Created by Neel Makhecha on 9/5/25.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var monitor: HLSMonitorViewModel
    @StateObject private var browser: BrowserViewModel
    @FocusState private var urlFieldFocused: Bool
    @State private var isBrowserExpanded = false
    @State private var interfaceIsLandscape: Bool = false
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let monitor = HLSMonitorViewModel()
        _monitor = StateObject(wrappedValue: monitor)
        _browser = StateObject(wrappedValue: BrowserViewModel(monitor: monitor))
    }

    var body: some View {
        // The root ZStack fills the window naturally (no explicit frame that can
        // collapse to zero on the first layout pass and cause a black screen).
        // GeometryReader is used only to decide orientation and split proportions.
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            GeometryReader { geometry in
                // Prefer the live geometry when it is valid; otherwise fall back to
                // the interface orientation so the very first launch is correct even
                // before SwiftUI reports a real size.
                let hasValidGeometry = geometry.size.width > 0 && geometry.size.height > 0
                let isLandscape = hasValidGeometry
                    ? geometry.size.width > geometry.size.height
                    : interfaceIsLandscape

                let size = hasValidGeometry ? geometry.size : fallbackSize()

                Group {
                    if isLandscape {
                        landscapeLayout(size: size)
                    } else {
                        portraitLayout(size: size)
                    }
                }
                .frame(width: size.width, height: size.height)
                .animation(.easeInOut(duration: 0.25), value: isBrowserExpanded)
                .animation(.easeInOut(duration: 0.3), value: isLandscape)
            }
        }
        .ignoresSafeArea(.keyboard)
        .onAppear { interfaceIsLandscape = ContentView.currentInterfaceIsLandscape() }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            interfaceIsLandscape = ContentView.currentInterfaceIsLandscape()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Returning to the foreground (e.g. after the phone was unlocked)
            // can leave the web view's video stalled. Re-prime playback.
            if newPhase == .active {
                interfaceIsLandscape = ContentView.currentInterfaceIsLandscape()
                browser.recoverPlaybackAfterForeground()
            }
        }
    }

    /// A best-effort screen size for the first layout pass, read from the active
    /// window scene (avoids the deprecated, scene-unaware `UIScreen.main`).
    private func fallbackSize() -> CGSize {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        if let bounds = scene?.screen.bounds, bounds.width > 0, bounds.height > 0 {
            return bounds.size
        }
        return CGSize(width: 390, height: 844)
    }

    /// Reads the live interface orientation from the active window scene.
    private static func currentInterfaceIsLandscape() -> Bool {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.interfaceOrientation.isLandscape ?? false
    }

    private var browserSection: some View {
        VStack(spacing: 0) {
            urlBar
            if browser.isLoading {
                ProgressView(value: browser.progress)
                    .progressViewStyle(.linear)
                    .tint(.blue)
            }
            ZStack {
                // A neutral backdrop so an empty web view never shows as a bare
                // black rectangle on first launch (before any URL is loaded).
                Color(.secondarySystemBackground)

                if browser.hasContent {
                    BrowserWebView(webView: browser.webView)
                } else {
                    emptyBrowserPlaceholder
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyBrowserPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("Enter a livestream URL")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Type an HLS (.m3u8) or web page URL above to start monitoring.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private func portraitLayout(size: CGSize) -> some View {
        VStack(spacing: 0) {
            browserSection
                .frame(height: isBrowserExpanded ? size.height : size.height / 2)

            if !isBrowserExpanded {
                Divider()

                MonitorPanelView(monitor: monitor)
                    .frame(maxHeight: .infinity)
            }
        }
    }

    private func landscapeLayout(size: CGSize) -> some View {
        HStack(spacing: 0) {
            browserSection
                .frame(width: isBrowserExpanded ? size.width : size.width / 2)

            if !isBrowserExpanded {
                Divider()

                MonitorPanelView(monitor: monitor)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var urlBar: some View {
        HStack(spacing: 10) {
            Button(action: browser.goBack) {
                Image(systemName: "chevron.left")
            }
            .disabled(!browser.canGoBack)

            Button(action: browser.goForward) {
                Image(systemName: "chevron.right")
            }
            .disabled(!browser.canGoForward)

            HStack(spacing: 6) {
                Image(systemName: "globe")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Enter URL or .m3u8 link", text: $browser.urlText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($urlFieldFocused)
                    .onSubmit {
                        urlFieldFocused = false
                        browser.submitURL()
                    }
                if !browser.urlText.isEmpty && urlFieldFocused {
                    Button {
                        browser.urlText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(.secondarySystemBackground), in: Capsule())

            Button(action: browser.reload) {
                Image(systemName: "arrow.clockwise")
            }

            Menu {
                Toggle(isOn: $browser.rememberURL) {
                    Label("Remember URL", systemImage: "bookmark")
                }
                if browser.savedURL != nil {
                    Section("Saved stream") {
                        if let saved = browser.savedURL {
                            Text(saved)
                        }
                        Button(role: .destructive) {
                            browser.clearSavedURL()
                        } label: {
                            Label("Clear Saved URL", systemImage: "trash")
                        }
                    }
                }
            } label: {
                Image(systemName: browser.savedURL != nil ? "bookmark.fill" : "bookmark")
            }

            Button {
                isBrowserExpanded.toggle()
            } label: {
                Image(systemName: isBrowserExpanded
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

#Preview {
    ContentView()
}
