import Foundation

/// Fetches and navigates Plex play queues for skip next/previous
struct PlexPlayQueueManager {

    struct QueueItem {
        let key: String             // e.g. "/library/metadata/26715"
        let ratingKey: String       // e.g. "26715"
        let title: String
        let playQueueItemID: Int    // queue-specific item ID
    }

    struct FetchResult {
        let items: [QueueItem]
        let currentIndex: Int?
        let playQueueVersion: Int
    }

    /// Fetch the play queue and return items, current index, and version
    static func fetch(
        containerKey: String,
        address: String,
        port: Int,
        serverProtocol: String,
        token: String,
        currentMediaKey: String
    ) async throws -> FetchResult {
        // containerKey looks like "/playQueues/10472?own=1"
        let baseURL = "\(serverProtocol)://\(address):\(port)"
        let separator = containerKey.contains("?") ? "&" : "?"
        guard let url = URL(string: "\(baseURL)\(containerKey)\(separator)X-Plex-Token=\(token)") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(token, forHTTPHeaderField: "X-Plex-Token")

        let (data, _) = try await URLSession.shared.data(for: request)
        return parseQueue(data: data, currentMediaKey: currentMediaKey)
    }

    private static func parseQueue(data: Data, currentMediaKey: String) -> FetchResult {
        let parser = PlayQueueXMLParser(currentMediaKey: currentMediaKey)
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parser
        xmlParser.parse()
        return FetchResult(items: parser.items, currentIndex: parser.currentIndex, playQueueVersion: parser.playQueueVersion)
    }
}

// Simple XML parser for play queue response
private class PlayQueueXMLParser: NSObject, XMLParserDelegate {
    var items: [PlexPlayQueueManager.QueueItem] = []
    var currentIndex: Int?
    let currentMediaKey: String
    private var selectedOffset: Int?
    var playQueueVersion: Int = 1

    init(currentMediaKey: String) {
        self.currentMediaKey = currentMediaKey
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if elementName == "MediaContainer" {
            if let offset = attributes["playQueueSelectedItemOffset"] {
                selectedOffset = Int(offset)
            }
            if let ver = attributes["playQueueVersion"] {
                playQueueVersion = Int(ver) ?? 1
            }
        }

        // Queue items are Video, Track, Photo elements
        if let key = attributes["key"], let ratingKey = attributes["ratingKey"],
           ["Video", "Track", "Photo"].contains(elementName) {
            let title = attributes["title"] ?? "Unknown"
            let pqItemID = Int(attributes["playQueueItemID"] ?? "0") ?? 0
            items.append(PlexPlayQueueManager.QueueItem(key: key, ratingKey: ratingKey, title: title, playQueueItemID: pqItemID))
        }
    }

    func parserDidEndDocument(_ parser: XMLParser) {
        // Prefer matching by key (since we manage our own position via skip)
        if let keyIdx = items.firstIndex(where: { $0.key == currentMediaKey }) {
            currentIndex = keyIdx
        } else if let offset = selectedOffset, offset >= 0, offset < items.count {
            // Fallback: use server's selected offset
            currentIndex = offset
        }
    }
}
