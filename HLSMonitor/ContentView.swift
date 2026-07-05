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
        GeometryReader { geometry in
            // On the very first launch in landscape, SwiftUI can briefly report
            // portrait-sized geometry before the scene finishes rotating. Fall
            // back to the actual interface orientation until geometry settles so
            // we render the correct layout immediately.
            let hasValidGeometry = geometry.size.width > 0 && geometry.size.height > 0
            let geometryLandscape = geometry.size.width > geometry.size.height
            let isLandscape = (!hasValidGeometry || geometry.size.width == geometry.size.height)
                ? interfaceIsLandscape
                : geometryLandscape

            Group {
                if isLandscape {
                    landscapeLayout(geometry: geometry)
                } else {
                    portraitLayout(geometry: geometry)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.25), value: isBrowserExpanded)
            .animation(.easeInOut(duration: 0.3), value: isLandscape)
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
            BrowserWebView(webView: browser.webView)
        }
    }

    private func portraitLayout(geometry: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            browserSection
                .frame(height: isBrowserExpanded ? geometry.size.height : geometry.size.height / 2)

            if !isBrowserExpanded {
                Divider()

                MonitorPanelView(monitor: monitor)
                    .frame(maxHeight: .infinity)
            }
        }
    }

    private func landscapeLayout(geometry: GeometryProxy) -> some View {
        HStack(spacing: 0) {
            browserSection
                .frame(width: isBrowserExpanded ? geometry.size.width : geometry.size.width / 2)

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
