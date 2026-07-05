//
//  MonitorScripts.swift
//  HLSMonitor
//
//  JavaScript injected into every page to intercept HLS network traffic
//  (fetch + XMLHttpRequest), observe <video> elements, and stream
//  playback stats back to the native layer.
//

import Foundation

enum MonitorScripts {

    static let interception = """
    (function() {
        if (window.__hlsMonitorInstalled) { return; }
        window.__hlsMonitorInstalled = true;

        function post(payload) {
            try {
                window.webkit.messageHandlers.hlsMonitor.postMessage(payload);
            } catch (e) {}
        }

        function classify(url) {
            if (!url) { return null; }
            var clean = url.split('?')[0].toLowerCase();
            if (clean.endsWith('.m3u8') || clean.indexOf('.m3u8') !== -1) { return 'manifest'; }
            if (clean.endsWith('.ts') || clean.endsWith('.m4s') || clean.endsWith('.mp4') ||
                clean.endsWith('.aac') || clean.endsWith('.fmp4') || clean.indexOf('/segment') !== -1) {
                return 'segment';
            }
            return null;
        }

        function absolute(url) {
            try { return new URL(url, document.baseURI).href; } catch (e) { return url; }
        }

        // Dedupe segments so the same load isn't counted by both the JS hooks
        // (hls.js style players) and the PerformanceObserver (native HLS engine).
        var seenSegments = Object.create(null);
        function reportSegment(url, durationMs, bytes) {
            var abs = absolute(url);
            var now = performance.now();
            var prev = seenSegments[abs];
            // Ignore a duplicate report for the same URL within a short window.
            if (prev && (now - prev) < 1500) { return; }
            seenSegments[abs] = now;
            post({
                type: 'segment',
                url: abs,
                durationMs: durationMs,
                bytes: bytes || 0
            });
        }

        // Report a failed segment download (network error or HTTP error status).
        var seenFailures = Object.create(null);
        function reportFailure(url, reason) {
            var abs = absolute(url);
            var now = performance.now();
            var prev = seenFailures[abs];
            if (prev && (now - prev) < 1500) { return; }
            seenFailures[abs] = now;
            post({
                type: 'segmentError',
                url: abs,
                reason: reason || 'error'
            });
        }

        // ---- fetch interception (covers MSE players like hls.js) ----
        var origFetch = window.fetch;
        window.fetch = function(input, init) {
            var url = (typeof input === 'string') ? input : (input && input.url);
            var kind = classify(url);
            if (kind === 'manifest') {
                post({ type: 'manifestRequest', url: absolute(url) });
                return origFetch.apply(this, arguments);
            }
            if (kind === 'segment') {
                var started = performance.now();
                return origFetch.apply(this, arguments).then(function(response) {
                    if (!response.ok) {
                        reportFailure(url, 'HTTP ' + response.status);
                    } else {
                        var bytes = parseInt(response.headers.get('content-length') || '0', 10);
                        reportSegment(url, performance.now() - started, bytes);
                    }
                    return response;
                }).catch(function(err) {
                    reportFailure(url, (err && err.message) ? err.message : 'network error');
                    throw err;
                });
            }
            return origFetch.apply(this, arguments);
        };

        // ---- PerformanceObserver (covers native HLS played by <video> directly) ----
        // On iOS/WKWebView many players hand the .m3u8 straight to the media
        // engine, which fetches .ts/.m4s segments internally — those never pass
        // through fetch/XHR. Resource Timing reports every request the page makes.
        function handleResourceEntry(entry) {
            var url = entry.name;
            var kind = classify(url);
            if (kind === 'manifest') {
                post({ type: 'manifestRequest', url: absolute(url) });
                return;
            }
            if (kind === 'segment') {
                var durationMs = entry.duration ||
                    (entry.responseEnd - entry.startTime) || 0;
                // responseStatus is available in newer WebKit; treat >=400 as a failure.
                if (typeof entry.responseStatus === 'number' && entry.responseStatus >= 400) {
                    reportFailure(url, 'HTTP ' + entry.responseStatus);
                    return;
                }
                // transferSize includes headers; encodedBodySize is the payload.
                var bytes = entry.encodedBodySize || entry.transferSize || 0;
                reportSegment(url, durationMs, bytes);
            }
        }

        try {
            if (window.PerformanceObserver) {
                var po = new PerformanceObserver(function(list) {
                    list.getEntries().forEach(handleResourceEntry);
                });
                po.observe({ type: 'resource', buffered: true });
            }
        } catch (e) {}

        // Fallback: some engines don't emit observable resource entries promptly,
        // so also poll the resource timing buffer periodically as a safety net.
        var lastResourceScan = 0;
        function scanResourceTiming() {
            try {
                var entries = performance.getEntriesByType('resource');
                for (var i = 0; i < entries.length; i++) {
                    var e = entries[i];
                    if (e.startTime <= lastResourceScan) { continue; }
                    handleResourceEntry(e);
                }
                if (entries.length) {
                    lastResourceScan = entries[entries.length - 1].startTime;
                }
                // Keep the buffer from growing unbounded on long streams.
                if (entries.length > 200 && performance.clearResourceTimings) {
                    performance.clearResourceTimings();
                    lastResourceScan = 0;
                }
            } catch (e) {}
        }

        // ---- XHR interception ----
        var origOpen = XMLHttpRequest.prototype.open;
        var origSend = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.open = function(method, url) {
            this.__hlsUrl = url;
            this.__hlsKind = classify(url);
            return origOpen.apply(this, arguments);
        };
        XMLHttpRequest.prototype.send = function() {
            var xhr = this;
            if (xhr.__hlsKind === 'manifest') {
                post({ type: 'manifestRequest', url: absolute(xhr.__hlsUrl) });
            } else if (xhr.__hlsKind === 'segment') {
                var started = performance.now();
                xhr.addEventListener('loadend', function() {
                    // status 0 means the request was aborted or failed at network level.
                    if (xhr.status === 0 || xhr.status >= 400) {
                        reportFailure(xhr.__hlsUrl, xhr.status === 0 ? 'network error' : 'HTTP ' + xhr.status);
                        return;
                    }
                    var bytes = 0;
                    try {
                        bytes = parseInt(xhr.getResponseHeader('content-length') || '0', 10);
                        if (!bytes && xhr.response && xhr.response.byteLength) {
                            bytes = xhr.response.byteLength;
                        }
                    } catch (e) {}
                    reportSegment(xhr.__hlsUrl, performance.now() - started, bytes);
                });
                xhr.addEventListener('error', function() {
                    reportFailure(xhr.__hlsUrl, 'network error');
                });
            }
            return origSend.apply(this, arguments);
        };

        // ---- video element observation ----
        var watchedVideos = new WeakSet();

        function checkSrc(el) {
            var src = el.currentSrc || el.src || '';
            if (classify(src) === 'manifest') {
                post({ type: 'manifestRequest', url: absolute(src) });
            }
        }

        function watchVideo(video) {
            if (watchedVideos.has(video)) { return; }
            watchedVideos.add(video);
            post({ type: 'event', name: 'videoFound', detail: video.currentSrc || video.src || '' });
            checkSrc(video);

            ['play', 'pause', 'ended', 'waiting', 'stalled', 'loadedmetadata'].forEach(function(name) {
                video.addEventListener(name, function() {
                    post({ type: 'event', name: name, detail: '' });
                    checkSrc(video);
                });
            });
            video.addEventListener('resize', function() {
                if (video.videoWidth > 0) {
                    post({
                        type: 'event',
                        name: 'qualityChange',
                        detail: video.videoWidth + 'x' + video.videoHeight
                    });
                }
            });
            video.addEventListener('error', function() {
                var err = video.error;
                post({ type: 'event', name: 'error', detail: err ? ('code ' + err.code) : 'unknown' });
            });
        }

        function scan() {
            document.querySelectorAll('video').forEach(watchVideo);
        }

        var observer = new MutationObserver(scan);
        function startObserving() {
            if (document.body) {
                observer.observe(document.body, { childList: true, subtree: true });
                scan();
            } else {
                setTimeout(startObserving, 250);
            }
        }
        startObserving();
        document.addEventListener('DOMContentLoaded', scan);

        // ---- periodic playback stats + resource-timing safety net ----
        setInterval(function() {
            scanResourceTiming();
            var video = document.querySelector('video');
            if (!video) { return; }
            var buffered = 0;
            try {
                if (video.buffered.length > 0) {
                    buffered = video.buffered.end(video.buffered.length - 1) - video.currentTime;
                }
            } catch (e) {}
            var dropped = 0, total = 0;
            try {
                if (video.getVideoPlaybackQuality) {
                    var q = video.getVideoPlaybackQuality();
                    dropped = q.droppedVideoFrames;
                    total = q.totalVideoFrames;
                }
            } catch (e) {}
            post({
                type: 'stats',
                width: video.videoWidth,
                height: video.videoHeight,
                currentTime: video.currentTime,
                buffered: Math.max(0, buffered),
                dropped: dropped,
                totalFrames: total,
                paused: video.paused
            });
        }, 1000);
    })();
    """
}
