//
//  ReportPDFRenderer.swift
//  HLSMonitor
//
//  Renders the report HTML to a single-page US Letter PDF with an offscreen
//  WKWebView. WebKit-only so the same file compiles in test harnesses.
//

import Foundation
import WebKit

@MainActor
final class ReportPDFRenderer: NSObject, WKNavigationDelegate {

    static let pageSize = CGRect(x: 0, y: 0, width: 612, height: 792)

    private var webView: WKWebView?
    private var completion: ((Result<Data, Error>) -> Void)?

    func render(html: String, completion: @escaping (Result<Data, Error>) -> Void) {
        let webView = WKWebView(frame: Self.pageSize)
        webView.navigationDelegate = self
        self.webView = webView
        self.completion = completion
        webView.loadHTMLString(html, baseURL: nil)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            let configuration = WKPDFConfiguration()
            configuration.rect = Self.pageSize
            webView.createPDF(configuration: configuration) { [weak self] result in
                self?.completion?(result)
                self?.completion = nil
                self?.webView = nil
            }
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        Task { @MainActor in
            completion?(.failure(error))
            completion = nil
            self.webView = nil
        }
    }
}
