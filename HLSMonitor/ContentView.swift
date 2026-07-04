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

    init() {
        let monitor = HLSMonitorViewModel()
        _monitor = StateObject(wrappedValue: monitor)
        _browser = StateObject(wrappedValue: BrowserViewModel(monitor: monitor))
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    urlBar
                    if browser.isLoading {
                        ProgressView(value: browser.progress)
                            .progressViewStyle(.linear)
                            .tint(.blue)
                    }
                    BrowserWebView(webView: browser.webView)
                }
                .frame(height: geometry.size.height / 2)

                Divider()

                MonitorPanelView(monitor: monitor)
                    .frame(maxHeight: .infinity)
            }
        }
        .ignoresSafeArea(.keyboard)
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
