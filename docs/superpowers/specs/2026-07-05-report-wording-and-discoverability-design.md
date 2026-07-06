# Report wording fix + discoverable quality-report button

Approved 2026-07-05.

## Problem

1. The quality report describes download gaps as "Silence between segments",
   which reads as *audio* silence. A download gap is a pause in segment
   *downloads* (`HLSMonitorViewModel.handleSegment`) and says nothing about
   the audio track.
2. The only entry point for sharing a quality report is an unlabeled
   `chart.bar.doc.horizontal` icon in the URL bar. Users don't discover that
   they can send a quality report at the end of a monitoring session.

## Design

### Wording

Replace "silence" with download-pause language:

- `QualityReportHTML.swift` incident table: "Pause in segment downloads —
  absorbed by the buffer" / "No segment downloads for over 2× the target
  duration".
- Code comments in `MonitorComponents.swift` and `HLSMonitorViewModel.swift`
  use the same terminology.

### QualityReportButton

New shared view (`Views/QualityReportButton.swift`): a full-width,
card-styled button (matching the `PanelBackground` rounded-rect card look)
that presents the existing `QualityReportSheet`.

- Label: report icon + "Share Quality Report" with a live subtitle.
- Subtitle states: "12m monitored · 143 segments" while a session has data;
  "N sessions from today ready to share" when only persisted sessions exist;
  "Available after monitoring a stream" otherwise (secondary-styled but still
  tappable — the sheet's empty state explains what to do).
- Data comes from the view model's published `segments`, a new read-only
  `sessionStartDate` accessor, and `sessionStore` — no new state or timers.

### Placement

- Directly under the web player in `ContentView.browserSection`, filling the
  letterboxed dead space below the video in every layout (phone portrait and
  landscape, iPad). Hidden while the browser is expanded so maximizing the
  video stays true to its name.
- The URL-bar toolbar icon in `ContentView` stays as a shortcut.

## Testing

View-layer change; existing tests untouched. Verified by building and
exercising the flow in the simulator.
