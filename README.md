# HLS Monitor for iOS

An iOS app for monitoring HLS (HTTP Live Streaming) video quality in real time. Inspired by the [HLS Monitor Chrome extension](https://kindlyops.github.io/hls-monitor/).

## Features

- **Built-in browser** (top half) — navigate to any website with a video player, or paste a direct `.m3u8` link to play it directly. Tap the expand button to go full screen (handy for logging in), then tap again to restore the split view.
- **Live Stats** — resolution, buffer health, dropped frames, and segment throughput for the active stream.
- **Streams** — detected master/media playlists with all quality renditions, highlighting the currently active one.
- **Events** — a live log of manifest requests, segment loads, quality switches, buffering, and errors.

## Project Structure

- `HLSMonitor/Browser/` — WKWebView wrapper and injected JavaScript that hooks into HLS network activity.
- `HLSMonitor/Monitor/` — view model and M3U8 manifest parser powering the monitoring panel.
- `HLSMonitor/Views/` — the monitoring panel UI (Live Stats / Streams / Events tabs).
- `HLSMonitor/Models/` — data models for streams, renditions, and events.

## Requirements

- iOS 26.0+
- Real device recommended for accurate hardware decoding stats (dropped frames, buffer behavior).
