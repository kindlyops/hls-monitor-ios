//
//  ManifestParser.swift
//  HLSMonitor
//

import Foundation

struct ParsedManifest {
    var isMaster: Bool
    var variants: [HLSVariant]
    var targetDuration: Double?
    var segmentCount: Int
    var isLive: Bool
}

enum ManifestParser {

    static func parse(_ text: String) -> ParsedManifest? {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard lines.first?.hasPrefix("#EXTM3U") == true else { return nil }

        var variants: [HLSVariant] = []
        var pendingAttributes: [String: String]?
        var targetDuration: Double?
        var segmentCount = 0
        var hasEndList = false

        for line in lines {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pendingAttributes = parseAttributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
            } else if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                targetDuration = Double(line.dropFirst("#EXT-X-TARGETDURATION:".count))
            } else if line.hasPrefix("#EXTINF:") {
                segmentCount += 1
            } else if line.hasPrefix("#EXT-X-ENDLIST") {
                hasEndList = true
            } else if !line.hasPrefix("#") {
                if let attrs = pendingAttributes {
                    let bandwidth = Int(attrs["BANDWIDTH"] ?? "") ?? 0
                    let resolution = attrs["RESOLUTION"]
                    let height = resolution?.split(separator: "x").last.flatMap { Int($0) }
                    let frameRate = attrs["FRAME-RATE"].flatMap { Double($0) }
                    variants.append(
                        HLSVariant(
                            bandwidth: bandwidth,
                            resolution: resolution,
                            height: height,
                            codecs: attrs["CODECS"],
                            frameRate: frameRate,
                            uri: line
                        )
                    )
                    pendingAttributes = nil
                }
            }
        }

        let isMaster = !variants.isEmpty
        return ParsedManifest(
            isMaster: isMaster,
            variants: variants.sorted { $0.bandwidth > $1.bandwidth },
            targetDuration: targetDuration,
            segmentCount: segmentCount,
            isLive: isMaster ? false : !hasEndList
        )
    }

    /// Parses HLS attribute lists like: BANDWIDTH=1280000,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2"
    static func parseAttributes(_ string: String) -> [String: String] {
        var result: [String: String] = [:]
        var key = ""
        var value = ""
        var inQuotes = false
        var parsingKey = true

        for character in string {
            if parsingKey {
                if character == "=" {
                    parsingKey = false
                } else {
                    key.append(character)
                }
            } else {
                if character == "\"" {
                    inQuotes.toggle()
                } else if character == "," && !inQuotes {
                    result[key.trimmingCharacters(in: .whitespaces)] = value
                    key = ""
                    value = ""
                    parsingKey = true
                } else {
                    value.append(character)
                }
            }
        }
        if !key.isEmpty {
            result[key.trimmingCharacters(in: .whitespaces)] = value
        }
        return result
    }
}
