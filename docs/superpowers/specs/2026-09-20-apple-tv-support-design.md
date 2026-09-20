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

## Scope

This started as a tvOS port and grew one section. The native measurement
source that tvOS forces us to build turns out to be worth shipping on iOS
as well, as a second player mode beside the browser — see section 3. That
changes the phase order, so the native source is built and validated on
iOS before any tvOS code depends on it.

The browser path is not going anywhere on iOS. Monitoring a third-party
site's player still requires a web view, and nothing here touches that.

## Platform facts this design rests on

Checked against Apple's documentation on 2026-09-20. These are the
constraints that decide the shape of the port, so they are recorded rather
than assumed.

| Capability | tvOS | Note |
| --- | --- | --- |
| `WKWebView`, `UIWebView`, `SFSafariViewController` | **No** | No supported way to embed a web view. TVMLKit is an app-templating system, not a browser engine. |
| `AVPlayerItem.accessLog()` / `errorLog()` | Yes, tvOS 9 | Every metric the port needs is present. |
| `AVAssetResourceLoader` custom-scheme interception | Playlists only | Segment redirects fail with `CoreMediaErrorDomain -12881`. |
| `MTAudioProcessingTap`, `AVAudioMix` | Yes, tvOS 9 | But not a supported route for HLS audio. See section 5. |
| `AVAudioSession` + `.playback` | Yes, tvOS 9 | |
| `UIGraphicsPDFRenderer` | Yes, tvOS 10 | |
| `ShareLink`, `UIActivityViewController`, document picker | **No** | No export path off the box at all. |
| SwiftUI `sheet`, `TextField`, `TabView` | Yes, tvOS 13 | |
| SwiftUI `Menu` | Yes, **tvOS 17** | Late arrival; sets a deployment-target floor. |
| Swift Charts | Yes, tvOS 16 | |
| Persistent local storage | **500 KB** | `UserDefaults` only. Everything else is purgeable. |
| Broadcast Upload Extension | Yes, tvOS 10 | Via `RPBroadcastActivityViewController`, not the iOS picker view. |
| AirPlay *receiver* API | **No** | Sender-side only. No way to observe what others AirPlay to the box. |

Current as of September 2026: tvOS 27, Xcode 27. Deployment target
**tvOS 26** gives the full current SwiftUI surface with one major version
of device coverage.

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
session store, the report HTML or the loudness maths knows that a web view
exists. Replacing the source of those messages is the whole job.

The bundled 543 KB `hls.min.js` and all 739 lines of injected script stay
iOS-only, and stay in use for the browser path.

## Design

### 1. A monitor source behind a protocol

Introduce a `MonitorSource` protocol whose only contract is producing the
message stream the view model already consumes, and give it two
implementations:

- `WebMonitorSource` — today's `BrowserViewModel`, unchanged in behaviour,
  renamed and conformed. iOS only.
- `NativeMonitorSource` — an `AVPlayer` plus observers that emit the same
  messages. The only source on tvOS, and a second player mode on iOS.

The message vocabulary stays as it is so the view model, the cards, the
charts and the report need no changes. The dictionary should become a
typed enum during the move, because a compiler-checked contract between two
producers is worth more than the dynamic one that a single JavaScript
producer made convenient.

### 2. Mapping each message to a native signal

| Message | Today (JavaScript) | Native |
| --- | --- | --- |
| `manifestRequest` | `fetch`/XHR/resource-timing hooks | The URL the user entered, plus every playlist URI the master parse yields. The view model's existing `fetchManifest` already handles the rest. |
| `stats` | `<video>` properties, `getVideoPlaybackQuality()` | `AVPlayerItem.presentationSize`, `loadedTimeRanges`, `currentTime()`, `timeControlStatus`; dropped frames from `numberOfDroppedVideoFrames`. |
| `event: stallStarted` / `stallEnded` | "currentTime frozen while not paused" detector | The same algorithm in Swift over `currentTime()` and `timeControlStatus`, corroborated by `AVPlayerItemPlaybackStalled` and the log's `numberOfStalls`. |
| `event: qualityChange` | `<video>` resize | `presentationSize` observation, and `indicatedBitrate` changing between log events. |
| `event: play`/`pause`/`ended`/`error` | media events | `timeControlStatus`, `AVPlayerItem.status`, `didPlayToEndTime`, `errorLog()`. |
| `segment` / `segmentError` | per-request `fetch` timing | The hard one. See section 4. |
| `audio` | Web Audio over hls.js remuxed PCM | Also hard, and not what you would expect. See section 5. |
| `airplay` | WebKit AirPlay events | On tvOS, dropped: the box is the receiver and there is no API to observe an inbound session. On iOS, `isExternalPlaybackActive` plus a native probe. See section 3. |

Three access-log properties are deprecated and should not be built on:
`numberOfSegmentsDownloaded`, `observedMaxBitrate`, `observedMinBitrate`.

The stall detector is worth porting rather than replacing. It deliberately
distinguishes a confirmed freeze from the raw `waiting`/`stalled` signals
that also fire during startup and seeks, and that distinction is what makes
the stall count in the quality report trustworthy.

### 3. The native source ships on iOS first

The iOS app already has two paths. Arbitrary web pages need the web view
and always will. But a direct `.m3u8` URL goes to `loadInlinePlayer`,
which builds a synthetic HTML page wrapping hls.js and a `<video>` tag. No
browsing happens on that path. It uses a web view for two reasons, and
`AVPlayer` removes both: hls.js fetches in JavaScript where the injected
script can see it, and it works around a WebKit bug where the built-in HLS
engine stalls at the end of the initial live window.

Four reasons to build `NativeMonitorSource` on iOS before tvOS needs it.

**Authenticity.** That path currently measures hls.js playing through
Media Source Extensions, which is not what an iPhone viewer in a native app
experiences. They get `AVPlayer`, with its own adaptive bitrate logic,
buffering behaviour and segment scheduling. Dropped frames read out of a
web view reflect WebKit compositing, not the hardware decoder.

**It is a feature, not just plumbing.** Offered as a user-visible choice
between the browser player and the native player, this answers a question
a stream QA tool should answer: does the problem reproduce in both engines?
A stream that plays clean in hls.js but stalls in `AVPlayer` is a common
and important bug class, covering bad fMP4 initialisation segments,
discontinuity handling and audio codec edge cases.

**AirPlay gets much simpler.** The probe subsystem added in #17 and #18
exists because MSE-fed video cannot AirPlay, and because page JavaScript
cannot read a cross-origin stream. Natively, the probe is a second muted
`AVPlayer` with `allowsExternalPlayback` disabled, and `URLSession` has no
same-origin policy. The entire `.dark(reason:)` CORS failure mode
disappears on this path. Retiring the JavaScript probe is deliberately
left to a later phase so the two can be compared first.

**It de-risks the tvOS work.** Developing the native source on iOS puts it
next to the hls.js path as a live reference implementation, on a platform
with a simulator, Safari tooling and real device logs. Running both sources
against the same stream and diffing their numbers is the correctness test
the native source needs, and tvOS is a poor place to discover it is wrong.

One caveat this path inherits: `AVPlayer` exposes only
`preferredPeakBitRate` as an adaptive bitrate lever, so pinning a specific
rendition is weaker than hls.js allows. Nothing in the app does that
today, but it constrains future work on the Streams card.

### 4. Per-segment metrics: the local proxy is the keystone

The download-time chart, the median/p95/peak table and the gap detector all
key off a `segment` message carrying a per-request duration and byte count.
`AVPlayer` does not hand those out. Three ways to close it:

**(a) Access log only.** `accessLog()` reports `numberOfBytesTransferred`,
`transferDuration`, `segmentsDownloadedDuration`, `observedBitrate`,
`indicatedBitrate`, `numberOfStalls`, `numberOfDroppedVideoFrames` and
`downloadOverdue`. No interception, no DRM problem, no risk to playback.
But a log event is appended on server or bitrate changes, not per segment,
so the chart becomes per-poll deltas rather than true per-segment samples.

**(b) Custom-scheme `AVAssetResourceLoaderDelegate`.** This does *not*
work for segments. AVFoundation supports custom schemes for playlists and
for key delivery; redirecting a segment request through one fails with
`CoreMediaErrorDomain -12881`. Useful for rewriting playlists, useless for
timing the fetches that matter.

**(c) Local HTTP proxy.** Serve playlists from `127.0.0.1` with their
segment URIs rewritten to point back at ourselves, so `AVPlayer` fetches
over ordinary HTTP and we time and size every request. Exact per-segment
data, byte-range preserved, and the existing chart and report code is
reused unchanged. Costs a small embedded server and an ATS
local-networking exception.

Option (c) is the design. It is what makes the native source match the
JavaScript one rather than approximate it, and section 5 makes loudness
depend on it too. Option (b) is not a path to per-segment data and should
only be considered as a playlist-rewriting mechanism if the proxy proves
troublesome. Option (a) is the fallback the app degrades to when the proxy
cannot be used, which the UI should state plainly rather than drawing a
chart implying precision it does not have.

The proxy carrying two features is the main structural risk in this design.
It should be spiked against real streams early, which is the other reason
the phase order below puts it first.

### 5. Loudness: harder than it looks

The obvious move is an `MTAudioProcessingTap` on the player item. It is
available on tvOS, and it does not solve this problem: audio taps operate
on `AVAsset`-backed items and are not a supported route for tapping HLS or
other remote-streamed audio.

Two routes that do work:

**Decode from the proxy.** Once the local proxy from section 4 is fetching
segments, it already holds the audio. Running the fetched segments through
`AVAssetReader` yields PCM to feed the existing
`LoudnessMeter.process(channels:sampleRate:)`. This is structurally the
same trick the iOS app already plays, where hls.js forwards remuxed audio
chunks to the injected meter — measure the stream's audio rather than the
device's output.

**ReplayKit, unexpectedly.** tvOS does support Broadcast Upload Extensions
— one of only six extension points it supports at all — so the existing
`LoudnessBroadcast` target could in principle port. The entry point
differs, `RPBroadcastActivityViewController` rather than the iOS
`RPSystemBroadcastPickerView`, and asking a viewer to start a system
broadcast with a remote is a poor experience. Worth knowing it exists; not
worth building first.

`LoudnessMeter` itself ports untouched. `SharedLoudness` and
`systemMeteringActive` stay fenced under `#if os(iOS)`, since the broadcast
path remains the iOS browser path's answer for players that keep audio out
of reach.

### 6. UI for a remote, not a finger

There is no browser on tvOS, so the shape of the app changes: enter a
stream, watch it full-screen, bring up a monitoring overlay.

- A full-screen player with a HUD the remote toggles, rather than the
  phone's split browser/panel layout.
- The five-card carousel becomes five top-level tabs. The page-style
  `TabView` and the custom pill indicator are both iOS-only constructs and
  the tvOS tab bar is the better fit anyway.
- Every `onTapGesture` becomes a focusable `Button`. The `insetGrouped`
  list style has no tvOS equivalent.
- Overscan-safe margins and `focusSection` grouping throughout.
- The custom `LineChart` is plain SwiftUI and ports as is. Swift Charts is
  available if it is ever worth replacing.
- `Menu` requires tvOS 17, below the proposed tvOS 26 target, so the
  bookmark menu ports. It is the one API in the UI layer with a meaningful
  version floor.

**Text entry is the UX risk.** Typing an `.m3u8` URL on a remote is
miserable. Mitigations, in order of value: lean hard on the existing
remembered-URL and test-stream buttons as large focusable targets; the iOS
Remote app's keyboard works for free; and later, a "send from your phone"
path that lets the existing iOS app hand a URL to the Apple TV over the
local network.

### 7. Storage is the sharpest constraint

`SessionStore` writes `monitoring-sessions.json` into the Documents
directory. On tvOS an app gets **500 KB of persistent local storage, via
`UserDefaults`, and nothing else** — every other on-disk location is
purgeable by the system when space runs low and the app is not running.
Apple's guidance is that anything which must survive belongs in iCloud
key-value storage, capped at 1 MB, or CloudKit.

Today's write is a `try?`, so on tvOS the failure mode is silent loss of
every session. The initialiser already accepts an injected `fileURL`, so
the mechanism is there; what it needs is a tvOS backing store that respects
the cap. The session records are small, but a week of them is not
obviously under 500 KB, so the retention window needs to be enforced by
size rather than only by age.

### 8. Reports

`ReportPDFRenderer` is `WKWebView.createPDF`, which is gone on tvOS.
`UIGraphicsPDFRenderer` is available there, so a PDF *can* still be
produced — but there is no `ShareLink`, no activity controller and no
document picker, so there is no way to hand the file to the user. A report
can only leave an Apple TV over the network.

For the first tvOS release, render the report on screen from the existing
session data and leave PDF export to iOS, where nothing changes.
`QualityReportHTML` is a pure string builder, so it stays shared for
whenever an off-device delivery path is worth building.

### 9. Project structure

Extract a local Swift package, `HLSMonitorCore`, containing the models,
manifest parser, loudness meter, session store, report HTML, view model and
the native source, with `.iOS` and `.tvOS` platforms declared. Both app
targets depend on it, and the existing test suite moves into the package
where it can run against both platforms.

The alternative — a second target in the existing project — fights the
file-system-synchronized groups this project uses, because per-target file
membership then has to be expressed as a growing list of membership
exceptions. That is exactly what a two-platform split produces a lot of.

Ship the tvOS app under the existing bundle identifier as a second platform
of the same App Store record, so it is a universal purchase rather than a
separate product.

## Phases

| Phase | Scope | Ships to users |
| --- | --- | --- |
| 0 | Extract `HLSMonitorCore`; iOS app behaviour unchanged | no |
| 1 | Local HTTP proxy; validated on iOS against the hls.js numbers | no |
| 2 | `NativeMonitorSource` as a second iOS player mode, with loudness | yes, iOS |
| 3 | tvOS target: focus UI, storage fix, on-screen report | yes, tvOS |
| 4 | Native AirPlay probe retires the JS probe; URL handoff from the phone | yes, both |

Two orderings were considered. This one is fidelity-first: the proxy and
the native source are proven on iOS, where there is a reference
implementation to diff against, before tvOS depends on them. The
alternative ships a tvOS app on access-log metrics at phase 1 and retrofits
the proxy later, which reaches the Apple TV store sooner at the cost of a
first release that is visibly thinner than the iOS app. Fidelity-first is
the recommendation, but if being on tvOS sooner matters more, the
alternative is legitimate and the phases are independent enough to swap.

Phase 0 is worth keeping separate and merging on its own: it touches every
file in the iOS app and should be proven to change nothing before anything
lands on top of it.

## Assets and release

- **App icon**: tvOS uses a layered parallax image stack of two to five
  layers at an 800×480 layout size, assembled in Xcode's asset catalog
  rather than Icon Composer. Layers must be rectangular and unmasked, with
  a safe zone because the system crops foreground layers during focus.
  There are no dark or tinted variants. The current catalog has one
  universal 1024×1024 iOS icon and nothing tvOS can use.
- **Top Shelf**: a static fallback image at 2320×720 pt at minimum.
  Dynamic layouts are preferred and need a Top Shelf extension, which is
  optional.
- **Launch screen**: required on tvOS, and static rather than layered.
- tvOS screenshots at 1920×1080 for App Store Connect, and a tvOS section
  in `docs/app-store/metadata.md`.
- `create-release-archive.sh` hardcodes `generic/platform=iOS`; it needs a
  tvOS destination alongside it.

## Risks

1. **The proxy carries two features.** Both exact segment metrics and
   loudness depend on it, on both platforms. If it proves unworkable
   against real streams, the native source is permanently thinner than the
   JavaScript one. Phase 1 exists to find that out early and cheaply.
2. **Regressing the iOS direct-`.m3u8` path.** Today it is the most
   instrumented thing the app has. Switching it to `AVPlayer` before the
   proxy lands would lose exact segment timing and loudness, which is why
   the native source is phase 2 and not phase 1, and why the browser player
   stays available rather than being replaced.
3. **DRM.** The proxy is blind to FairPlay content, and key delivery goes
   through `AVContentKeySession` rather than the resource loader. The app
   should detect encrypted streams and say so rather than showing empty
   cards.
4. **Text entry on tvOS.** If the remembered-URL and test-stream paths are
   not genuinely good, the app is unusable on a remote. Worth prototyping
   first.
5. **Silent storage loss.** Covered in section 7, but it is the kind of bug
   that only shows up after a week of use.

## Testing

The core package's existing tests (`LoudnessMeterTests`,
`MonitoringSessionTests`) run unchanged on both platforms and are the
regression net for phase 0.

The native source gets a test the tvOS-only plan could not have offered: on
iOS, both sources can play the same stream and their message streams can be
diffed. Segment counts, byte totals, download-time distributions and
quality-switch counts should agree within tolerance, and where they do not,
the discrepancy is either a bug in the native source or a real difference
between the two playback engines — both worth knowing. This is the primary
acceptance criterion for phase 2.

Unit coverage is still needed for the stall detector and the
quality-change detector, since both are heuristics re-derived from
different signals than the JavaScript versions used.

## Aside

`Utils/ApiKeyManager.swift` (248 lines, `CryptoKit` + Keychain) and
`ENCRYPTED_KEYS.plist` have no references anywhere in the tree. Worth
deleting during phase 0 rather than porting.
