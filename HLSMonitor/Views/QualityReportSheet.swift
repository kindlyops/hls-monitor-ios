//
//  QualityReportSheet.swift
//  HLSMonitor
//
//  Builds and shares the single-page PDF quality report. When several
//  same-day sessions monitored the same stream URL, the user chooses
//  between consolidating them or reporting only the most recent.
//

import SwiftUI

struct QualityReportSheet: View {
    @ObservedObject var monitor: HLSMonitorViewModel
    @Environment(\.dismiss) private var dismiss

    private enum Scope: Hashable {
        case mostRecent
        case consolidated
    }

    @State private var scope: Scope = .mostRecent
    @State private var candidates: [MonitoringSession] = []
    @State private var pdfURL: URL?
    @State private var isRendering = false
    @State private var renderError: String?
    @State private var renderer = ReportPDFRenderer()

    var body: some View {
        NavigationStack {
            Group {
                if candidates.isEmpty {
                    ContentUnavailableView(
                        "No monitoring data",
                        systemImage: "chart.bar.doc.horizontal",
                        description: Text("Play and monitor a stream first; sessions from today will be reportable here.")
                    )
                } else {
                    reportForm
                }
            }
            .navigationTitle("Quality Report")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(Color("PaperBackground"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear(perform: loadCandidates)
    }

    private var reportForm: some View {
        Form {
            Section("Stream") {
                Text(candidates.last?.streamURL ?? "")
                    .font(.caption.monospaced())
                    .lineLimit(3)
                LabeledContent("Sessions today", value: "\(candidates.count)")
            }

            if candidates.count > 1 {
                Section("Scope") {
                    Picker("Report scope", selection: $scope) {
                        Text("Most recent session").tag(Scope.mostRecent)
                        Text("Consolidate all \(candidates.count)").tag(Scope.consolidated)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }

            if let session = selectedSession {
                Section("Summary") {
                    LabeledContent("Monitored", value: durationText(session.monitoredSeconds))
                    LabeledContent("Segments", value: "\(session.segmentCount)")
                    LabeledContent("Failures", value: "\(session.failureCount)")
                    LabeledContent("Gaps / stalls",
                                   value: "\(session.gapCount) / \(session.stallCount)")
                }
            }

            Section {
                if let pdfURL {
                    ShareLink(item: pdfURL) {
                        Label("Share PDF Report", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Button {
                        generate()
                    } label: {
                        if isRendering {
                            HStack {
                                ProgressView()
                                Text("Rendering…")
                            }
                        } else {
                            Label("Generate PDF Report", systemImage: "doc.richtext")
                        }
                    }
                    .disabled(isRendering || selectedSession == nil)
                }
                if let renderError {
                    Text(renderError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .onChange(of: scope) { _, _ in pdfURL = nil }
    }

    private var selectedSession: MonitoringSession? {
        switch scope {
        case .mostRecent:
            return candidates.last
        case .consolidated:
            return MonitoringSession.consolidate(candidates)
        }
    }

    /// Today's persisted sessions for the current stream URL, plus a live
    /// snapshot of the in-progress session, oldest first.
    private func loadCandidates() {
        let snapshot = monitor.snapshotSession()
        let url = snapshot?.streamURL
            ?? monitor.sessionStreamURL
            ?? monitor.sessionStore.sessions.last?.streamURL
        guard let url else {
            candidates = []
            return
        }
        var sessions = monitor.sessionStore.sessions(matching: url, sameDayAs: Date())
        if let snapshot, snapshot.streamURL == url {
            sessions.append(snapshot)
        }
        candidates = sessions
        scope = .mostRecent
        pdfURL = nil
    }

    private func generate() {
        guard let session = selectedSession else { return }
        isRendering = true
        renderError = nil
        let html = QualityReportHTML.page(for: session)
        renderer.render(html: html) { result in
            isRendering = false
            switch result {
            case .success(let data):
                let name = "stream-quality-report-\(Int(session.endDate.timeIntervalSince1970)).pdf"
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                do {
                    try data.write(to: url, options: .atomic)
                    pdfURL = url
                } catch {
                    renderError = "Could not save the PDF: \(error.localizedDescription)"
                }
            case .failure(let error):
                renderError = "Rendering failed: \(error.localizedDescription)"
            }
        }
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total >= 3600 { return String(format: "%dh %02dm", total / 3600, (total % 3600) / 60) }
        if total >= 60 { return String(format: "%dm %02ds", total / 60, total % 60) }
        return "\(total)s"
    }
}
