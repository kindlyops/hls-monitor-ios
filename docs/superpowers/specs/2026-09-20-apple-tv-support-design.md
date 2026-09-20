# Apple TV (tvOS) support

Draft 2026-09-20. Not yet approved.

## Problem

HLSMonitor measures stream quality by injecting JavaScript into a
`WKWebView` and listening to what the page's player does. tvOS has no
WebKit framework, so the measurement layer — not just the UI — has to be
rebuilt on a native player before the app can run on an Apple TV.

Apple TV is also where the streams being tested are actually watched. A
monitor that runs on the same box, on the same network, through the same
decoder, measures what the viewer gets rather than what an iPhone two rooms
away gets. That is the reason to do this at all.

## What ports and what doesn't

Measured against the current tree:

| Bucket | Lines | Files |
| --- | --- | --- |
| Portable unchanged | ~1,600 | `Models/`, `ManifestParser`, `HLSMonitorViewModel`, `LoudnessMeter`, `MonitoringSession`, `QualityReportHTML` |
| Will not compile on tvOS | ~1,200 | `Browser/MonitorScripts`, `Browser/BrowserWebView`, `Report/ReportPDFRenderer` |
| Compiles but needs focus/layout rework | ~1,900 | `ContentView`, `Views/` |

The single most important fact in this table: `HLSMonitorViewModel`
already takes its input through one untyped funnel,
`handle(_ body: [String: Any])`, and does its own manifest fetching and
parsing over `URLSession`. Nothing in the view model, the models, the
session store, the report HTML, or the loudness maths knows that a web
view exists. Replacing the source of those messages is the whole job.

`LoudnessMeter` is pure `AVFoundation`/`CoreMedia` and already exposes
`process(channels:sampleRate:)`, which is exactly the shape a native audio
tap feeds. The bundled 543 KB `hls.min.js` and all 739 lines of injected
script become iOS-only.

## Design

### 1. A monitor source behind a protocol

Introduce a `MonitorSource` protocol whose only contract is producing the
message stream the view model already consumes, and give it two
implementations:

- `WebMonitorSource` (iOS) — today's `BrowserViewModel`, unchanged in
  behaviour, renamed and conformed.
- `NativeMonitorSource` (tvOS, and usable on iOS for direct `.m3u8`
  playback) — an `AVPlayer` plus observers that emit the same messages.

The message vocabulary stays as it is so the view model, the cards, the
charts and the report need no changes. The dictionary should become a
typed enum during the move, because a compiler-checked contract between
two producers is worth more than the dynamic one that a single JavaScript
producer made convenient.

### 2. Mapping each message to a native signal

| Message | Today (JavaScript) | Native (tvOS) |
| --- | --- | --- |
| `manifestRequest` | `fetch`/XHR/resource-timing hooks | The URL the user entered, plus every playlist URI the master parse yields. The view model's existing `fetchManifest` already handles the rest. |
| `stats` | `<video>` properties, `getVideoPlaybackQuality()` | `AVPlayerItem.presentationSize`, `loadedTimeRanges`, `currentTime()`, `timeControlStatus`; dropped frames from the access log. |
| `event: stallStarted` / `stallEnded` | "currentTime frozen while not paused" detector | The same algorithm in Swift over `currentTime()` and `timeControlStatus`, corroborated by `AVPlayerItemPlaybackStalled`. |
| `event: qualityChange` | `<video>` resize | `presentationSize` observation, and the access log's indicated bitrate changing. |
| `event: play`/`pause`/`ended`/`error` | media events | `timeControlStatus`, `AVPlayerItem.status`, `didPlayToEndTime`, the error log. |
| `audio` | Web Audio over hls.js remuxed PCM | An audio tap on the player item, feeding the existing `LoudnessMeter`. |
| `segment` / `segmentError` | per-request `fetch` timing | The hard one. See below. |
| `airplay` | WebKit AirPlay events | Dropped. The Apple TV is the receiver; there is no outbound session to go dark. |

The stall detector is worth porting rather than replacing. It deliberately
distinguishes a confirmed freeze from the raw `waiting`/`stalled` signals
that also fire during startup and seeks, and that distinction is what makes
the stall count in the quality report trustworthy.

### 3. Per-segment metrics: the one real gap

The download-time chart, the median/p95/peak table and the gap detector all
key off a `segment` message carrying a per-request duration and byte count.
`AVPlayer` does not hand those out. Three ways to close it:

**(a) Access log only.** `AVPlayerItem.accessLog()` reports transferred
bytes, observed and indicated bitrate, stall count, dropped frames, and
download-overdue counts. No interception, no DRM problem, no risk to
playback. But a log event is appended on server or bitrate changes, not per
segment, so the chart becomes per-poll deltas rather than true per-segment
samples.

**(b) Custom-scheme `AVAssetResourceLoaderDelegate`.** Rewrite the scheme
so every request routes through our delegate, and time our own fetches.
True per-segment fidelity, at the cost of re-implementing byte-range and
live-edge handling, and it cannot work on FairPlay content.

**(c) Local HTTP proxy.** Serve playlists from `127.0.0.1`, rewritten to
point segment URIs back at ourselves. Exact per-segment bytes and timing,
byte-range preserved, and the existing chart and report code is reused
unchanged. Costs a small embedded server and an ATS local-networking
exception.

Recommendation: ship **(a)** first so the app exists, then add **(c)**
behind a "deep probe" toggle for unencrypted streams. Do not start with
(b); it has (c)'s complexity and less of its fidelity.

This is the one place where the tvOS app is honestly weaker than the iOS
app until phase 3 lands, and the UI should say so rather than draw a chart
that implies per-segment precision it doesn't have.

### 4. Loudness gets better, not worse

On iOS, metering audio that the page plays natively requires the user to
start a ReplayKit broadcast and pick "HLSMonitor Loudness" from a system
sheet. That whole path — `LoudnessBroadcast`, the app group, the
`RPSystemBroadcastPickerView` — is iOS-only and unnecessary on tvOS.

Owning the player means owning the audio. An audio tap on the player item
feeds PCM straight into the existing `LoudnessMeter`, so LUFS is live from
the first frame with nothing for the user to start. `SharedLoudness` and
`systemMeteringActive` get fenced under `#if os(iOS)`.

Caveat: a tap sees decoded PCM only. Streams that pass audio through
untouched, and DRM-protected audio, will still read as unavailable.

### 5. UI for a remote, not a finger

There is no browser, so the shape of the app changes: enter a stream, watch
it full-screen, bring up a monitoring overlay.

- A full-screen player with a HUD the remote toggles, rather than the
  phone's split browser/panel layout.
- The five-card carousel becomes five top-level tabs. The page-style
  `TabView` and the custom pill indicator are both iOS-only constructs and
  the tvOS tab bar is the better fit anyway.
- Every `onTapGesture` becomes a focusable `Button`. `insetGrouped` list
  style has no tvOS equivalent.
- Overscan-safe margins and `focusSection` grouping throughout.
- The custom `LineChart` is plain SwiftUI and ports as is.

**Text entry is the UX risk.** Typing an `.m3u8` URL on a remote is
miserable. Mitigations, in order of value: lean hard on the existing
remembered-URL and test-stream buttons as large focusable targets; the iOS
Remote app's keyboard works for free; and later, a "send from your phone"
path that lets the existing iOS app hand a URL to the Apple TV over the
local network.

### 6. Storage

`SessionStore` writes `monitoring-sessions.json` into the Documents
directory. tvOS does not give apps persistent Documents storage — the
write will fail, and because it is a `try?` it will fail silently and lose
every session. The initialiser already accepts an injected `fileURL`, so
the fix is a platform-specific default (caches directory, with the small
session JSON mirrored into key-value storage so a purge doesn't erase
history).

### 7. Reports

`ReportPDFRenderer` is `WKWebView.createPDF`, which is gone. tvOS also has
no share sheet, no Files app and no document picker, so even a rendered PDF
has nowhere to go.

For the first release, render the report on screen from the existing
session data and leave PDF export to iOS. `QualityReportHTML` is a pure
string builder, so it stays shared for whenever an off-device delivery path
(upload, email, or handoff to the phone) is worth building.

### 8. Project structure

Extract a local Swift package, `HLSMonitorCore`, containing the models,
manifest parser, loudness meter, session store, report HTML and view model,
with `.iOS` and `.tvOS` platforms declared. Both app targets depend on it,
and the existing test suite moves into the package where it can run against
both platforms.

The alternative — a second target in the existing project — fights the
file-system-synchronized groups this project uses, because per-target file
membership then has to be expressed as a growing list of membership
exceptions. That is exactly what a two-platform split produces a lot of.

Ship the tvOS app under the existing bundle identifier as a second platform
of the same App Store record, so it is a universal purchase rather than a
separate product.

## Phases

| Phase | Scope | Shippable |
| --- | --- | --- |
| 0 | Extract `HLSMonitorCore`; iOS app behaviour unchanged | no |
| 1 | tvOS target, `AVPlayer` playback, access-log metrics, focus UI | yes |
| 2 | Loudness via an audio tap | yes |
| 3 | Exact per-segment metrics via the local proxy | yes |
| 4 | Report on screen, URL handoff from the phone | yes |

Phase 0 is worth keeping separate and merging on its own: it touches every
file in the iOS app and should be proven to change nothing before any tvOS
code lands on top of it.

## Assets and release

- Layered tvOS app icon and Top Shelf artwork; the current asset catalog has
  a single universal 1024×1024 iOS icon and nothing tvOS can use.
- tvOS screenshots at 1920×1080 for App Store Connect.
- A tvOS section in `docs/app-store/metadata.md`.
- `create-release-archive.sh` hardcodes `generic/platform=iOS`; it needs a
  tvOS destination alongside it.

## Risks

1. **Per-segment fidelity.** The download-time chart is the app's signature
   view and phases 1–2 can only approximate it. Mitigated by phase 3 and by
   labelling the approximation honestly until then.
2. **DRM.** Both the audio tap and the proxy are blind to FairPlay content.
   The app should detect it and say so rather than showing empty cards.
3. **Text entry.** If the remembered-URL and test-stream paths are not
   genuinely good, the app is unusable on a remote. Worth prototyping first.
4. **Silent storage loss.** Covered above, but it is the kind of bug that
   only shows up after a week of use.

## Testing

The core package's existing tests (`LoudnessMeterTests`,
`MonitoringSessionTests`) run unchanged on both platforms and are the
regression net for phase 0. New coverage is needed for the native source's
message mapping — the stall detector and the quality-change detector in
particular, since both are heuristics being re-derived from different
signals than the JavaScript versions used.

## Aside

`Utils/ApiKeyManager.swift` (248 lines, `CryptoKit` + Keychain) and
`ENCRYPTED_KEYS.plist` have no references anywhere in the tree. Worth
deleting during phase 0 rather than porting.
