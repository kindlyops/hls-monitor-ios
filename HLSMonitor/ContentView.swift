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
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let monitor = HLSMonitorViewModel()
        _monitor = StateObject(wrappedValue: monitor)
        _browser = StateObject(wrappedValue: BrowserViewModel(monitor: monitor))
    }

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        // Choose layout from the size class (available immediately — it never
        // collapses to zero the way a top-level GeometryReader's size can on the
        // first layout pass, which was leaving the window fully black on launch).
        // A compact vertical size class means landscape on iPhone.
        ZStack {
            // Guaranteed-visible backdrop. Because this is a plain, unconditional
            // full-screen view, the window can never come up as a bare black
            // rectangle even during the very first layout pass.
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            Group {
                if horizontalSizeClass == .regular {
                    // iPad (and iPad Split View wide enough for a regular
                    // width): dashboard layout with every monitor card visible.
                    padLayout
                } else if verticalSizeClass == .compact {
                    landscapeLayout
                } else {
                    portraitLayout
                }
            }
            .animation(.easeInOut(duration: 0.25), value: isBrowserExpanded)
        }
        .ignoresSafeArea(.keyboard)
        .onAppear {
            // Now that the hierarchy is mounted and the web view has a window,
            // it's safe to auto-open a remembered stream.
            browser.loadRememberedStreamIfNeeded()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Returning to the foreground (e.g. after the phone was unlocked)
            // can leave the web view's video stalled. Re-prime playback.
            if newPhase == .active {
                browser.recoverPlaybackAfterForeground()
            }
        }
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

    private var padLayout: some View {
        // The GeometryReader only picks which arrangement to use; children size
        // themselves with flexible frames, so a transient zero size on the
        // first pass cannot blank the screen.
        GeometryReader { geo in
            if geo.size.width > geo.size.height {
                // Landscape: browser fills the left, dashboard column on the right.
                HStack(spacing: 0) {
                    browserSection
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if !isBrowserExpanded {
                        Divider()

                        MonitorDashboardView(monitor: monitor)
                            .frame(width: min(430, geo.size.width * 0.42))
                    }
                }
            } else {
                // Portrait: browser on top, two-column card grid below.
                VStack(spacing: 0) {
                    browserSection
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if !isBrowserExpanded {
                        Divider()

                        MonitorDashboardView(monitor: monitor, columns: 2)
                            .frame(height: geo.size.height * 0.5)
                    }
                }
            }
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
