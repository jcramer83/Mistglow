import Foundation

enum PlexMediaResolver {
    struct MediaInfo {
        let directPlayURL: URL
        let transcodeURL: URL?
        let title: String
        let duration: Int // milliseconds
        let key: String
        let audioStreamIndex: Int? // FFmpeg absolute stream index for selected audio
        let audioStreams: [(index: Int, plexID: String, language: String)]
        let thumbURL: URL?
        let showTitle: String?    // grandparentTitle (TV show name)
        let seasonNumber: Int?    // parentIndex
        let episodeNumber: Int?   // index
        let videoHeight: Int?     // source video height from Plex metadata
        let videoWidth: Int?      // source video width from Plex metadata

        var displayTitle: String {
            if let show = showTitle, let s = seasonNumber, let e = episodeNumber {
                return "\(show) — S\(s)E\(e) — \(title)"
            } else if let show = showTitle {
                return "\(show) — \(title)"
            }
            return title
        }
    }

    /// Extract real local IP from plex.direct hostname
    /// e.g. "192-168-1-41.xxxxx.plex.direct" -> "192.168.1.41"
    private static func extractLocalIP(from address: String) -> String? {
        guard address.contains("plex.direct") else { return nil }
        // First segment before "." contains the IP with dashes
        let firstSegment = String(address.split(separator: ".").first ?? "")
        let ip = firstSegment.replacingOccurrences(of: "-", with: ".")
        let octets = ip.split(separator: ".")
        if octets.count == 4, octets.allSatisfy({ Int($0) != nil }) {
            return ip
        }
        return nil
    }

    static func resolve(
        address: String, port: Int, serverProtocol: String,
        key: String, token: String,
        clientIdentifier: String? = nil, sessionIdentifier: String? = nil
    ) async throws -> MediaInfo {
        // Prefer local IP with http to avoid certificate issues
        let localIP = extractLocalIP(from: address)
        let baseURL: String
        if let localIP {
            baseURL = "http://\(localIP):\(port)"
        } else {
            baseURL = "\(serverProtocol)://\(address):\(port)"
        }

        // Fetch metadata
        let metadataURL = URL(string: "\(baseURL)\(key)?X-Plex-Token=\(token)")!

        var request = URLRequest(url: metadataURL)
        request.setValue("Mistglow", forHTTPHeaderField: "X-Plex-Product")
        request.setValue("application/xml", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        let (data, _) = try await URLSession.shared.data(for: request)
        let parser = MetadataParser(data: data)
        let result = parser.parse()

        guard let partKey = result.partKey else {
            throw PlexError.noMediaPart
        }

        // Direct play URL — include client/session identifiers so PMS creates a tracked session
        var directURLStr = "\(baseURL)\(partKey)?X-Plex-Token=\(token)"
        if let cid = clientIdentifier {
            directURLStr += "&X-Plex-Client-Identifier=\(cid)"
        }
        if let sid = sessionIdentifier {
            directURLStr += "&X-Plex-Session-Identifier=\(sid)"
        }
        let directURL = URL(string: directURLStr)!

        // HLS transcode URL (works for everything — AVPlayer loves HLS)
        var transcodeURLStr = "\(baseURL)/video/:/transcode/universal/start.m3u8?path=\(key)&mediaIndex=0&partIndex=0&protocol=hls&directStream=1&directPlay=0&X-Plex-Token=\(token)&X-Plex-Product=Mistglow&X-Plex-Platform=macOS"
        if let cid = clientIdentifier {
            transcodeURLStr += "&X-Plex-Client-Identifier=\(cid)"
        }
        if let sid = sessionIdentifier {
            transcodeURLStr += "&X-Plex-Session-Identifier=\(sid)"
        }
        let transcodeURL = URL(string: transcodeURLStr)

        // Log audio streams found
        for stream in parser.audioStreams {
            print("Plex audio stream: index=\(stream.index) plexID=\(stream.plexID) lang=\(stream.language) selected=\(stream.selected) default=\(stream.isDefault)")
        }
        if let idx = parser.selectedAudioStreamIndex {
            print("Plex: Selected audio stream index=\(idx)")
        }

        // Build thumb URL (prefer grandparentThumb for show art, fall back to thumb)
        let thumbPath = result.grandparentThumb ?? result.thumb
        let thumbURL: URL?
        if let thumbPath {
            thumbURL = URL(string: "\(baseURL)\(thumbPath)?X-Plex-Token=\(token)")
        } else {
            thumbURL = nil
        }

        // FFmpeg handles all formats directly - always use direct play
        return MediaInfo(
            directPlayURL: directURL,
            transcodeURL: transcodeURL,
            title: result.title ?? "Unknown",
            duration: result.duration,
            key: key,
            audioStreamIndex: result.selectedAudioStreamIndex,
            audioStreams: result.audioStreams.map { (index: $0.index, plexID: $0.plexID, language: $0.language) },
            thumbURL: thumbURL,
            showTitle: result.grandparentTitle,
            seasonNumber: result.parentIndex,
            episodeNumber: result.episodeIndex,
            videoHeight: result.videoHeight,
            videoWidth: result.videoWidth
        )
    }

    enum PlexError: Error, LocalizedError {
        case noMediaPart

        var errorDescription: String? {
            switch self {
            case .noMediaPart: return "No playable media part found"
            }
        }
    }
}

// MARK: - XML Parser for Plex metadata

private class MetadataParser: NSObject, XMLParserDelegate {
    private let data: Data
    var title: String?
    var duration: Int = 0
    var partKey: String?
    var selectedAudioStreamIndex: Int?
    var thumb: String?
    var grandparentThumb: String?
    var grandparentTitle: String?
    var parentIndex: Int?
    var episodeIndex: Int?
    var videoHeight: Int?
    var videoWidth: Int?
    private var foundPart = false
    // Track audio streams to find the selected/default one
    var audioStreams: [(index: Int, plexID: String, language: String, selected: Bool, isDefault: Bool)] = []

    init(data: Data) {
        self.data = data
    }

    func parse() -> MetadataParser {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()

        // Pick selected audio stream, or default, or first English, or first
        if let selected = audioStreams.first(where: { $0.selected }) {
            selectedAudioStreamIndex = selected.index
        } else if let def = audioStreams.first(where: { $0.isDefault }) {
            selectedAudioStreamIndex = def.index
        } else if let eng = audioStreams.first(where: { $0.language.hasPrefix("eng") }) {
            selectedAudioStreamIndex = eng.index
        } else if let first = audioStreams.first {
            selectedAudioStreamIndex = first.index
        }

        return self
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes: [String: String] = [:]) {
        switch elementName {
        case "Video":
            title = attributes["title"]
            if let d = attributes["duration"], let ms = Int(d) {
                duration = ms
            }
            thumb = attributes["thumb"]
            grandparentThumb = attributes["grandparentThumb"]
            grandparentTitle = attributes["grandparentTitle"]
            if let pi = attributes["parentIndex"] { parentIndex = Int(pi) }
            if let ei = attributes["index"] { episodeIndex = Int(ei) }
        case "Media":
            if videoHeight == nil, let h = attributes["height"], let hi = Int(h) {
                videoHeight = hi
            }
            if videoWidth == nil, let w = attributes["width"], let wi = Int(w) {
                videoWidth = wi
            }
        case "Part":
            if partKey == nil {
                partKey = attributes["key"]
                foundPart = true
            }
        case "Stream":
            // streamType 2 = audio
            if foundPart, attributes["streamType"] == "2",
               let indexStr = attributes["index"], let index = Int(indexStr) {
                let plexID = attributes["id"] ?? ""
                let language = attributes["languageCode"] ?? attributes["language"] ?? ""
                let selected = attributes["selected"] == "1"
                let isDefault = attributes["default"] == "1"
                audioStreams.append((index: index, plexID: plexID, language: language, selected: selected, isDefault: isDefault))
            }
        default:
            break
        }
    }
}
