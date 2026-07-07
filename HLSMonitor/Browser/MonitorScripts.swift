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

        // ---- playback recovery after backgrounding ----
        // When the app is backgrounded (phone locked), WebKit suspends the media
        // decode pipeline. On return to the foreground the <video> element can be
        // left stalled — the network layer keeps fetching segments but no frames
        // are decoded/rendered, and a plain play() won't restart the decoder.
        // Nudging currentTime forces the media engine to rebuild its pipeline.
        function recoverPlayback() {
            document.querySelectorAll('video').forEach(function(video) {
                try {
                    // Leave AirPlay sessions alone: playback continues on the
                    // remote device while the app is hidden, and a seek here
                    // would disrupt it.
                    if (video.webkitCurrentPlaybackTargetIsWireless) { return; }
                    // Only resume streams that were meant to be playing.
                    var wasPlaying = !video.paused && !video.ended;
                    var live = !isFinite(video.duration) || video.duration === 0;

                    // A tiny seek kicks the decoder back to life. For live streams,
                    // jump to the live edge of the buffered range so we don't sit
                    // on a stale position that may already have been evicted.
                    if (video.buffered && video.buffered.length > 0) {
                        var end = video.buffered.end(video.buffered.length - 1);
                        var start = video.buffered.start(0);
                        var target = video.currentTime;
                        if (live) {
                            target = Math.max(start, end - 0.5);
                        } else {
                            target = Math.min(end - 0.05, Math.max(start, video.currentTime + 0.01));
                        }
                        if (isFinite(target) && Math.abs(target - video.currentTime) > 0.001) {
                            video.currentTime = target;
                        }
                    }

                    if (wasPlaying) {
                        var p = video.play();
                        if (p && typeof p.catch === 'function') { p.catch(function() {}); }
                    }
                    post({ type: 'event', name: 'recovered', detail: live ? 'live' : 'vod' });
                } catch (e) {
                    post({ type: 'event', name: 'error', detail: 'recovery failed' });
                }
            });
        }
        // Exposed so the native layer can trigger recovery on scene activation.
        window.__hlsRecoverPlayback = recoverPlayback;

        // Also self-heal when the page regains visibility.
        document.addEventListener('visibilitychange', function() {
            if (!document.hidden) {
                // Small delay lets WebKit finish resuming the media session first.
                setTimeout(recoverPlayback, 300);
            }
        });

        // ---- audio loudness (BS.1770-style K-weighted LUFS) ----
        // WebKit renders <video> audio outside the page's audio graph
        // (MediaElementAudioSourceNode yields silence for both MSE and native
        // HLS playback), so loudness is measured from the stream content
        // instead: the inline player forwards each remuxed audio segment
        // here, and the PCM is decoded and K-weighted off the playback path.
        var audioMeter = {
            initSeg: null,
            decodeCtx: null,
            queue: [],
            busy: false,
            hopMS: [],      // 100ms hop mean squares (rolling 3s window)
            blocks: [],     // 400ms momentary-block mean squares for gating
            sumSq: 0,
            samplesIntoHop: 0,
            hopSamples: 0,
            sampleRate: 0,
            lastPeakDb: null,
            gotData: false,
            playingTicks: 0,
            unavailableSent: false
        };

        function lufs(meanSquare) {
            if (!(meanSquare > 0)) { return null; }
            return -0.691 + 10 * Math.log10(meanSquare);
        }

        function meanTail(arr, count) {
            if (arr.length < count) { return null; }
            var sum = 0;
            for (var i = arr.length - count; i < arr.length; i++) { sum += arr[i]; }
            return sum / count;
        }

        // BS.1770 gating: drop blocks under the -70 LUFS absolute gate, then
        // under a relative gate 10 LU below the mean of what remains.
        function integratedLufs(blocks) {
            var absGated = [];
            for (var i = 0; i < blocks.length; i++) {
                var l = lufs(blocks[i]);
                if (l !== null && l > -70) { absGated.push(blocks[i]); }
            }
            if (!absGated.length) { return null; }
            var mean = 0;
            for (var j = 0; j < absGated.length; j++) { mean += absGated[j]; }
            mean /= absGated.length;
            var relThreshold = lufs(mean) - 10;
            var sum = 0, n = 0;
            for (var k = 0; k < absGated.length; k++) {
                var lk = lufs(absGated[k]);
                if (lk !== null && lk > relThreshold) { sum += absGated[k]; n++; }
            }
            return n ? lufs(sum / n) : null;
        }

        // Called by the inline player with the audio init segment.
        window.__hlsMonitorAudioInit = function(bytes) {
            audioMeter.initSeg = new Uint8Array(bytes);
        };

        // Called by the inline player with each remuxed audio media segment.
        window.__hlsMonitorAudioChunk = function(bytes) {
            audioMeter.queue.push(new Uint8Array(bytes));
            // Never build a decode backlog; dropping old chunks only thins
            // the measurement, it cannot corrupt it.
            if (audioMeter.queue.length > 8) { audioMeter.queue.shift(); }
            processAudioQueue();
        };

        function processAudioQueue() {
            if (audioMeter.busy || !audioMeter.queue.length) { return; }
            var AC = window.AudioContext || window.webkitAudioContext;
            if (!AC) { return; }
            if (!audioMeter.decodeCtx) { audioMeter.decodeCtx = new AC(); }
            var chunk = audioMeter.queue.shift();
            var init = audioMeter.initSeg;
            var full = chunk;
            if (init) {
                full = new Uint8Array(init.length + chunk.length);
                full.set(init, 0);
                full.set(chunk, init.length);
            }
            audioMeter.busy = true;
            audioMeter.decodeCtx.decodeAudioData(
                full.buffer.slice(0),
                function(buffer) {
                    kWeighAndAccumulate(buffer);
                },
                function() {
                    audioMeter.busy = false;
                    processAudioQueue();
                }
            );
        }

        function kWeighAndAccumulate(buffer) {
            // Unweighted sample peak straight off the decoded PCM.
            var peak = 0;
            for (var c = 0; c < buffer.numberOfChannels; c++) {
                var d = buffer.getChannelData(c);
                for (var i = 0; i < d.length; i++) {
                    var a = Math.abs(d[i]);
                    if (a > peak) { peak = a; }
                }
            }
            audioMeter.lastPeakDb = peak > 0 ? 20 * Math.log10(peak) : null;

            var Offline = window.OfflineAudioContext || window.webkitOfflineAudioContext;
            if (!Offline) {
                audioMeter.busy = false;
                return;
            }
            var off = new Offline(buffer.numberOfChannels, buffer.length, buffer.sampleRate);
            var source = off.createBufferSource();
            source.buffer = buffer;
            // Approximate K-weighting: pre-emphasis shelf then RLB high-pass.
            var shelf = off.createBiquadFilter();
            shelf.type = 'highshelf';
            shelf.frequency.value = 1681.97;
            shelf.gain.value = 3.99984;
            var rlb = off.createBiquadFilter();
            rlb.type = 'highpass';
            rlb.frequency.value = 38.13;
            rlb.Q.value = 0.5;
            source.connect(shelf);
            shelf.connect(rlb);
            rlb.connect(off.destination);
            source.start();
            off.startRendering().then(function(rendered) {
                accumulateWeighted(rendered);
                audioMeter.gotData = true;
                postAudioLevels();
                audioMeter.busy = false;
                processAudioQueue();
            }).catch(function() {
                audioMeter.busy = false;
                processAudioQueue();
            });
        }

        function accumulateWeighted(rendered) {
            if (audioMeter.sampleRate !== rendered.sampleRate) {
                audioMeter.sampleRate = rendered.sampleRate;
                audioMeter.hopSamples = Math.round(rendered.sampleRate / 10);
                audioMeter.sumSq = 0;
                audioMeter.samplesIntoHop = 0;
            }
            var channels = [];
            for (var c = 0; c < rendered.numberOfChannels; c++) {
                channels.push(rendered.getChannelData(c));
            }
            for (var i = 0; i < rendered.length; i++) {
                var sq = 0;
                for (var c2 = 0; c2 < channels.length; c2++) {
                    var v = channels[c2][i];
                    sq += v * v;
                }
                audioMeter.sumSq += sq;
                audioMeter.samplesIntoHop++;
                if (audioMeter.samplesIntoHop >= audioMeter.hopSamples) {
                    audioMeter.hopMS.push(audioMeter.sumSq / audioMeter.hopSamples);
                    if (audioMeter.hopMS.length > 30) { audioMeter.hopMS.shift(); }
                    if (audioMeter.hopMS.length >= 4) {
                        var block = 0;
                        for (var h = audioMeter.hopMS.length - 4; h < audioMeter.hopMS.length; h++) {
                            block += audioMeter.hopMS[h];
                        }
                        // Cap the gating history at one hour of blocks.
                        if (audioMeter.blocks.length < 36000) {
                            audioMeter.blocks.push(block / 4);
                        }
                    }
                    audioMeter.sumSq = 0;
                    audioMeter.samplesIntoHop = 0;
                }
            }
        }

        function postAudioLevels() {
            post({
                type: 'audio',
                state: 'metering',
                momentary: lufs(meanTail(audioMeter.hopMS, 4)),
                shortTerm: lufs(meanTail(audioMeter.hopMS, 30)),
                integrated: integratedLufs(audioMeter.blocks),
                peak: audioMeter.lastPeakDb
            });
        }

        function postAudioUnavailable() {
            if (audioMeter.unavailableSent) { return; }
            audioMeter.unavailableSent = true;
            post({ type: 'audio', state: 'unavailable' });
        }

        // Watchdog: report metering as unavailable when audio can never
        // arrive — native HLS playback, or a third-party MSE player that
        // does not feed segments to this page's meter.
        setInterval(function() {
            if (audioMeter.gotData || audioMeter.unavailableSent) { return; }
            var video = document.querySelector('video');
            if (!video || video.paused || !video.currentSrc) { return; }
            if (video.currentSrc.indexOf('blob:') !== 0) {
                postAudioUnavailable();
                return;
            }
            audioMeter.playingTicks++;
            if (audioMeter.playingTicks >= 12) {
                postAudioUnavailable();
            }
        }, 1000);

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

            // Confirmed-stall detection. Raw waiting/stalled events are a
            // weak proxy for viewer-visible freezes: they fire during
            // startup buffering, after seeks, and (stalled especially)
            // while playback continues fine from buffer. A stall only
            // counts once playback has started, the element is playing,
            // and currentTime stays frozen past a perceptual threshold.
            // Exactly one stallStarted/stallEnded pair is posted per
            // freeze, with the measured duration in ms on stallEnded.
            var STALL_CONFIRM_MS = 250;
            var stall = { suppressed: true, pendingSince: 0, frozenAt: -1, confirmed: false };
            function endStall() {
                if (stall.confirmed) {
                    post({
                        type: 'event',
                        name: 'stallEnded',
                        detail: String(Math.round(Date.now() - stall.pendingSince))
                    });
                }
                stall.confirmed = false;
                stall.pendingSince = 0;
                stall.frozenAt = -1;
            }
            video.addEventListener('playing', function() {
                endStall();
                stall.suppressed = false;
            });
            // Startup buffering and seek buffering are expected loading,
            // not interruptions: suppress until playback (re)starts.
            video.addEventListener('seeking', function() {
                endStall();
                stall.suppressed = true;
            });
            ['pause', 'ended', 'emptied'].forEach(function(name) {
                video.addEventListener(name, endStall);
            });
            ['waiting', 'stalled'].forEach(function(name) {
                video.addEventListener(name, function() {
                    if (stall.suppressed || video.paused || stall.pendingSince) { return; }
                    stall.pendingSince = Date.now();
                    stall.frozenAt = video.currentTime;
                });
            });
            setInterval(function() {
                if (!stall.pendingSince) { return; }
                if (video.currentTime !== stall.frozenAt) {
                    // Playback moved on: a confirmed stall just ended, an
                    // unconfirmed one was too brief for anyone to see.
                    endStall();
                    return;
                }
                if (!stall.confirmed && Date.now() - stall.pendingSince >= STALL_CONFIRM_MS) {
                    stall.confirmed = true;
                    post({ type: 'event', name: 'stallStarted', detail: '' });
                }
            }, 100);
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
