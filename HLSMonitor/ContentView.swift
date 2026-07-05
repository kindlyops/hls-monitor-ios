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
        // Layout uses only flexible frames (maxWidth/maxHeight) so it can never
        // collapse to a zero-sized frame on the first pass and show a black
        // launch screen. Orientation is tracked as a simple boolean driven by
        // the interface orientation rather than a GeometryReader wrapping an
        // explicit width/height frame.
        content
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .animation(.easeInOut(duration: 0.25), value: isBrowserExpanded)
            .animation(.easeInOut(duration: 0.3), value: interfaceIsLandscape)
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

    @ViewBuilder
    private var content: some View {
        if interfaceIsLandscape {
            landscapeLayout
        } else {
            portraitLayout
        }
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

    private var portraitLayout: some View {
        VStack(spacing: 0) {
            browserSection
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(isBrowserExpanded ? 1 : 0)

            if !isBrowserExpanded {
                Divider()

                MonitorPanelView(monitor: monitor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var landscapeLayout: some View {
        HStack(spacing: 0) {
            browserSection
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(isBrowserExpanded ? 1 : 0)

            if !isBrowserExpanded {
                Divider()

                MonitorPanelView(monitor: monitor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
