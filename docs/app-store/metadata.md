# App Store Connect metadata

Everything to paste into App Store Connect for the first release. Character
limits are noted; all fields below fit them.

## App name (30 chars max)

```
HLSMonitor
```

Alternative if you want the store listing to say what it does:
`HLSMonitor: Live Stream QA` (21).

## Subtitle (30 chars max)

```
HLS stream quality monitor
```
(26 chars)

## Promotional text (170 chars max, editable without a new build)

```
Point at any HLS stream and watch quality the way a viewer would —
segment timing, stalls, bitrate ladder, loudness — then share a one-page
PDF quality report.
```
(≈160 chars — paste as a single paragraph, no line breaks)

## Description (4000 chars max)

```
HLSMonitor plays a live stream the way your viewers watch it — in a real
browser-based player — and measures delivery quality while it plays.

Open an .m3u8 URL directly, or load any web page with an HLS player in it.
HLSMonitor detects the manifests and media segments automatically and starts
recording.

WHAT IT MEASURES

• Segment downloads: every request, with median, p95, and peak download
  times charted against real-time playback so you can see the player
  falling behind before viewers do
• Failures: segment requests that error or return HTTP 400+
• Download gaps: stretches with no segment downloads for more than twice
  the target duration
• Playback stalls: only confirmed, viewer-visible freezes are counted,
  with measured durations
• Rendition switches: watch ABR move through the quality ladder, with
  every variant's resolution, codecs, and bitrate listed from the master
  playlist
• Audio loudness: LUFS momentary, short-term, and integrated loudness
  with true peak, metered from the inline player or from device audio via
  a screen-broadcast extension (levels only — nothing is recorded or
  uploaded)

SHARE A QUALITY REPORT

When the session ends, generate a one-page PDF: monitored duration,
segments, throughput, a timeline of quality events, incident counts with
plain-language explanations, and a verdict based on what viewers actually
experienced. Sessions from the same day can be consolidated into one
report. Share it from the standard iOS share sheet.

WHO IT'S FOR

Broadcast engineers, streaming ops, video developers, and anyone who gets
asked "is the stream OK?" and wants an answer with numbers attached —
from wherever they happen to be standing.

HLSMonitor sends nothing anywhere. All monitoring happens on the device,
and the only thing that leaves it is the PDF if you choose to share.
```
(≈1,750 chars)

## Keywords (100 chars max, comma-separated)

```
hls,m3u8,stream,streaming,video,monitor,qa,bitrate,stall,latency,lufs,loudness,broadcast,cdn
```
(92 chars. Don't waste keywords on words already in the name/subtitle —
"monitor" is borderline; swap for `encoder` or `abr` if you rename.)

## What's New (first release)

```
Initial release.
```

## Screenshots (`docs/app-store/screenshots/`)

Only two sizes are required now; smaller devices scale down from these.
Upload in this order — the first three show in search results.

iPhone 6.5" (1284×2778, the size App Store Connect asked for):
1. `iphone-65-01-live-monitoring.png` — video playing over live playback/segment stats
2. `iphone-65-02-download-times.png` — segment download chart with percentiles
3. `iphone-65-03-renditions.png` — master playlist and bitrate ladder
4. `iphone-65-04-quality-report.png` — quality report sheet with Share PDF
5. `iphone-65-05-pdf-report.png` — the generated PDF quality report page

iPad 13" (2064×2752 / 2752×2064):
1. `ipad-13-01-dashboard.png` — full dashboard, portrait
2. `ipad-13-02-dashboard-landscape.png` — player + dashboard column, landscape
3. `ipad-13-03-pdf-report.png` — the generated PDF quality report page

## App preview (`docs/app-store/previews/`)

`iphone-65-preview.mp4` — 886×1920, 29.4s, 30fps H.264 with silent stereo
AAC (within Apple's 15–30s limit). Storyboard: load the Unified Streaming
test stream → live playback/segment stats → download-time chart →
rendition list → generate and share the PDF quality report. Upload to the
iPhone preview slot; pick a poster frame around the 6s mark (SMPTE bars +
live stats). Previews autoplay muted in the store.

## Categories

- Primary: Developer Tools
- Secondary: Utilities

## Other required fields

| Field | Suggested value |
|---|---|
| Age rating | Answer "unrestricted web access: YES" (the URL bar loads any page) → app gets 17+ |
| Copyright | © 2026 Kindly Ops, LLC |
| Support URL | https://github.com/kindlyops/hls-monitor-ios/issues |
| Privacy policy URL | required — a page stating no data is collected |
| App Privacy questionnaire | "Data not collected" (nothing leaves the device) |
| Pricing | your call — not set here |

## Review notes (App Review box)

```
HLSMonitor is a diagnostic tool for HLS video streams. The URL field exists
so engineers can load their own stream URLs or player pages; ATS arbitrary
loads are enabled because production streams are frequently served over
plain HTTP inside broadcast facilities. The screen-broadcast extension
("HLSMonitor Loudness") measures audio loudness levels only; no audio or
video is recorded, stored, or transmitted. To test: tap "Mux Live Test" on
the empty browser screen and the monitor starts automatically.
```

## Before submitting — build gaps to close

- [x] App icon: 1024×1024 icon exists in the asset catalog (alpha channel
      stripped 2026-07-05 — App Store Connect rejects icons with alpha)
- [ ] Distribution signing: current project uses "Sign to Run Locally";
      you'll need your team + App Store profile
- [ ] `NSAllowsArbitraryLoads` is enabled — keep the review note above, or
      scope it down if your streams are all HTTPS
- [ ] Version is 1.0 (build 1) from MARKETING_VERSION — bump per release
