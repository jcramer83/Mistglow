import Foundation
import Network

protocol PlexCompanionDelegate: AnyObject {
    func plexPlayMedia(serverAddress: String, serverPort: Int, serverProtocol: String,
                       key: String, token: String, offset: Int, machineIdentifier: String,
                       audioStreamID: String?, containerKey: String?)
    func plexStop()
    func plexPause()
    func plexResume()
    func plexSeek(to offsetMs: Int)
    func plexSkipNext()
    func plexSkipPrevious()
    func plexTimeline() -> PlexTimeline
}

struct PlexTimeline {
    var state: String = "stopped"
    var timeMs: Int = 0
    var durationMs: Int = 0
    var key: String = ""
    var machineIdentifier: String = ""
    var address: String = ""
    var port: Int = 32400
    var `protocol`: String = "http"
    var token: String = ""
    var containerKey: String = ""
    var playQueueItemID: Int = 0
    var playQueueID: Int = 0
    var playQueueVersion: Int = 1
}

final class PlexCompanionServer: @unchecked Sendable {
    private var listener: NWListener?
    private let port: UInt16
    private let queue = DispatchQueue(label: "com.mistglow.plex.companion", qos: .userInitiated)
    weak var delegate: PlexCompanionDelegate?
    var resourceIdentifier: String = ""
    var logHandler: ((String) -> Void)?
    /// Highest commandID received from any Plex command
    private var latestCommandID: Int = 0

    // Timeline subscription: push updates to subscribers
    private var timelineSubscribers: [(host: String, port: Int, commandID: String)] = []
    private var timelineTimer: DispatchSourceTimer?

    init(port: UInt16 = 3005) {
        self.port = port
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.log("Companion server ready on port \(self?.port ?? 0)")
            case .failed(let error):
                self?.log("Companion server failed: \(error)")
            default:
                break
            }
        }
        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        listener?.start(queue: queue)

        // Start timeline push timer (every 1 second)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            self?.pushTimelineToSubscribers()
        }
        timer.resume()
        self.timelineTimer = timer
    }

    func stop() {
        timelineTimer?.cancel()
        timelineTimer = nil
        listener?.cancel()
        listener = nil
        timelineSubscribers.removeAll()
    }

    private func log(_ msg: String) {
        logHandler?(msg)
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            guard let data, error == nil else {
                self.log("Plex: Connection error: \(error?.localizedDescription ?? "no data")")
                connection.cancel()
                return
            }
            guard let request = String(data: data, encoding: .utf8) else {
                self.log("Plex: Non-UTF8 request (\(data.count) bytes)")
                connection.cancel()
                return
            }

            // Check if this is a long-poll timeline request
            let lines = request.components(separatedBy: "\r\n")
            let parts = (lines.first ?? "").split(separator: " ")
            if parts.count >= 2 {
                let fullPath = String(parts[1])
                let (path, params) = self.parsePathAndQuery(fullPath)
                if path == "/player/timeline/poll" && params["wait"] == "1" {
                    // Long poll: delay ~950ms before responding
                    self.queue.asyncAfter(deadline: .now() + 0.95) { [weak self] in
                        guard let self else { connection.cancel(); return }
                        let response = self.handleRequest(request)
                        let responseData = response.data(using: .utf8) ?? Data()
                        connection.send(content: responseData, completion: .contentProcessed { _ in
                            connection.cancel()
                        })
                    }
                    return
                }
            }

            let response = self.handleRequest(request)
            let responseData = response.data(using: .utf8) ?? Data()
            connection.send(content: responseData, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func handleRequest(_ raw: String) -> String {
        let lines = raw.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return httpResponse(200, body: "") }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return httpResponse(200, body: "") }

        let method = String(parts[0])
        let fullPath = String(parts[1])
        var (path, queryParams) = parsePathAndQuery(fullPath)

        // Parse POST body as form-urlencoded and merge into query params
        if method == "POST" {
            if let bodyStart = raw.range(of: "\r\n\r\n") {
                let body = String(raw[bodyStart.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty {
                    let bodyParams = parseQueryString(body)
                    for (k, v) in bodyParams {
                        if queryParams[k] == nil {
                            queryParams[k] = v
                        }
                    }
                }
            }
        }

        // Also merge Plex headers into params as fallback
        for header in ["X-Plex-Token", "X-Plex-Target-Client-Identifier"] {
            if let val = extractHeader(lines, name: header), queryParams[header] == nil {
                queryParams[header] = val
            }
        }

        // Track highest commandID from any incoming command
        if let cidStr = queryParams["commandID"], let cid = Int(cidStr), cid > latestCommandID {
            latestCommandID = cid
        }

        // Log non-poll requests
        if !path.contains("timeline/poll") {
            log("Plex: \(method) \(path)")
        }

        // Handle CORS preflight
        if method == "OPTIONS" {
            return corsResponse()
        }

        switch path {
        case "/resources":
            return httpResponse(200, body: resourcesXML(), contentType: "text/xml")

        case "/player/playback/playMedia":
            let address = queryParams["address"] ?? ""
            let portStr = queryParams["port"] ?? "32400"
            let proto = queryParams["protocol"] ?? "http"
            let key = queryParams["key"] ?? ""
            let offset = Int(queryParams["offset"] ?? "0") ?? 0
            let machineId = queryParams["machineIdentifier"] ?? ""

            // Prefer the real X-Plex-Token over the transient token
            let headerToken = queryParams["X-Plex-Token"] ?? extractHeader(lines, name: "X-Plex-Token") ?? ""
            let queryToken = queryParams["token"] ?? ""
            // Use real token if available, fall back to transient
            let token = !headerToken.isEmpty ? headerToken : queryToken

            log("Plex: playMedia key=\(key)")

            let audioStreamID = queryParams["audioStreamID"]
            let containerKey = queryParams["containerKey"]

            delegate?.plexPlayMedia(
                serverAddress: address,
                serverPort: Int(portStr) ?? 32400,
                serverProtocol: proto,
                key: key,
                token: token,
                offset: offset,
                machineIdentifier: machineId,
                audioStreamID: audioStreamID,
                containerKey: containerKey
            )
            let tl = delegate?.plexTimeline() ?? PlexTimeline()
            return httpResponse(200, body: buildTimelineXML(tl, commandID: queryParams["commandID"]), contentType: "text/xml")

        case "/player/playback/stop":
            delegate?.plexStop()
            let tl = delegate?.plexTimeline() ?? PlexTimeline()
            return httpResponse(200, body: buildTimelineXML(tl, commandID: queryParams["commandID"]), contentType: "text/xml")

        case "/player/playback/pause":
            delegate?.plexPause()
            let tl = delegate?.plexTimeline() ?? PlexTimeline()
            return httpResponse(200, body: buildTimelineXML(tl, commandID: queryParams["commandID"]), contentType: "text/xml")

        case "/player/playback/play":
            delegate?.plexResume()
            let tl = delegate?.plexTimeline() ?? PlexTimeline()
            return httpResponse(200, body: buildTimelineXML(tl, commandID: queryParams["commandID"]), contentType: "text/xml")

        case "/player/playback/seekTo":
            let offset = Int(queryParams["offset"] ?? "0") ?? 0
            delegate?.plexSeek(to: offset)
            let tl = delegate?.plexTimeline() ?? PlexTimeline()
            return httpResponse(200, body: buildTimelineXML(tl, commandID: queryParams["commandID"]), contentType: "text/xml")

        case "/player/playback/skipNext":
            delegate?.plexSkipNext()
            let tl = delegate?.plexTimeline() ?? PlexTimeline()
            return httpResponse(200, body: buildTimelineXML(tl, commandID: queryParams["commandID"]), contentType: "text/xml")

        case "/player/playback/skipPrevious":
            delegate?.plexSkipPrevious()
            let tl = delegate?.plexTimeline() ?? PlexTimeline()
            return httpResponse(200, body: buildTimelineXML(tl, commandID: queryParams["commandID"]), contentType: "text/xml")

        case "/player/playback/stepBack":
            delegate?.plexSkipPrevious()
            let tl = delegate?.plexTimeline() ?? PlexTimeline()
            return httpResponse(200, body: buildTimelineXML(tl, commandID: queryParams["commandID"]), contentType: "text/xml")

        case "/player/playback/stepForward":
            delegate?.plexSkipNext()
            let tl = delegate?.plexTimeline() ?? PlexTimeline()
            return httpResponse(200, body: buildTimelineXML(tl, commandID: queryParams["commandID"]), contentType: "text/xml")

        // Navigation namespace (used by some Plex clients)
        case "/player/navigation/moveUp",
             "/player/navigation/moveDown",
             "/player/navigation/moveLeft",
             "/player/navigation/moveRight",
             "/player/navigation/select",
             "/player/navigation/back",
             "/player/navigation/home":
            return httpResponse(200, body: "")

        case "/player/timeline":
            let tl = delegate?.plexTimeline() ?? PlexTimeline()
            return httpResponse(200, body: buildTimelineXML(tl), contentType: "text/xml")

        case "/player/timeline/poll":
            let tl = delegate?.plexTimeline() ?? PlexTimeline()
            let commandID = queryParams["commandID"] ?? "0"
            let xml = buildTimelineXML(tl, commandID: commandID)
            return httpResponse(200, body: xml, contentType: "text/xml")

        case "/player/timeline/subscribe":
            let commandID = queryParams["commandID"] ?? "0"
            let subscriberPort = Int(queryParams["port"] ?? "32400") ?? 32400
            // Extract subscriber IP from X-Plex-Client-Identifier or connection
            let subscriberHost = extractHeader(lines, name: "Host")?.split(separator: ":").first.map(String.init) ?? ""
            if !subscriberHost.isEmpty {
                timelineSubscribers.removeAll { $0.host == subscriberHost }
                timelineSubscribers.append((host: subscriberHost, port: subscriberPort, commandID: commandID))
                log("Plex: Timeline subscriber added: \(subscriberHost):\(subscriberPort)")
            }
            let tl = delegate?.plexTimeline() ?? PlexTimeline()
            return httpResponse(200, body: buildTimelineXML(tl, commandID: commandID), contentType: "text/xml")

        case "/player/timeline/unsubscribe":
            let subscriberHost = extractHeader(lines, name: "Host")?.split(separator: ":").first.map(String.init) ?? ""
            timelineSubscribers.removeAll { $0.host == subscriberHost }
            return httpResponse(200, body: "")

        case "/player/mirror/details":
            return httpResponse(200, body: "")

        case "/player/playback/setParameters":
            return httpResponse(200, body: "")

        default:
            log("Plex: Unhandled path: \(path)")
            return httpResponse(200, body: "")
        }
    }

    // MARK: - Timeline Push

    private func pushTimelineToSubscribers() {
        guard !timelineSubscribers.isEmpty else { return }
        let tl = delegate?.plexTimeline() ?? PlexTimeline()

        for subscriber in timelineSubscribers {
            let xml = buildTimelineXML(tl, commandID: subscriber.commandID)
            guard let body = xml.data(using: .utf8),
                  let url = URL(string: "http://\(subscriber.host):\(subscriber.port)/:/timeline") else { continue }

            var request = URLRequest(url: url, timeoutInterval: 5)
            request.httpMethod = "POST"
            request.setValue("text/xml", forHTTPHeaderField: "Content-Type")
            request.httpBody = body

            URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
        }
    }

    // MARK: - Response Builders

    private func resourcesXML() -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
            + "<MediaContainer>\n"
            + "<Player title=\"MiSTer\" protocol=\"plex\" protocolVersion=\"1\" "
            + "protocolCapabilities=\"timeline,playback,navigation,playqueues\" "
            + "machineIdentifier=\"\(resourceIdentifier)\" "
            + "product=\"Mistglow\" platform=\"macOS\" platformVersion=\"14.0\" "
            + "deviceClass=\"stb\" />\n"
            + "</MediaContainer>"
    }

    private func buildTimelineXML(_ tl: PlexTimeline, commandID: String? = nil) -> String {
        let controllable = "playPause,stop,seekTo,skipPrevious,skipNext,volume,audioStream,subtitleStream,stepBack,stepForward"
        let isActive = tl.state == "playing" || tl.state == "paused" || tl.state == "buffering"
        let location = isActive ? "fullScreenVideo" : "navigation"
        // Echo back the controller's commandID — web app discards responses with mismatched commandID
        let cid = commandID ?? String(latestCommandID)

        var attrs = "type=\"video\" state=\"\(tl.state)\" time=\"\(tl.timeMs)\" duration=\"\(tl.durationMs)\""
        attrs += " controllable=\"\(controllable)\""
        attrs += " location=\"\(location)\""
        attrs += " volume=\"100\""
        if tl.durationMs > 0 {
            attrs += " seekRange=\"0-\(tl.durationMs)\""
        }
        if !tl.key.isEmpty {
            attrs += " key=\"\(xmlEscape(tl.key))\" ratingKey=\"\(tl.key.split(separator: "/").last ?? "")\""
            attrs += " machineIdentifier=\"\(xmlEscape(tl.machineIdentifier))\""
        }
        if !tl.containerKey.isEmpty {
            attrs += " containerKey=\"\(xmlEscape(tl.containerKey))\""
            if tl.playQueueID > 0 {
                attrs += " playQueueID=\"\(tl.playQueueID)\""
            }
            if tl.playQueueItemID > 0 {
                attrs += " playQueueItemID=\"\(tl.playQueueItemID)\" playQueueVersion=\"\(tl.playQueueVersion)\""
            }
        }
        // Server connection info so web app can look up metadata
        if !tl.address.isEmpty {
            attrs += " address=\"\(xmlEscape(tl.address))\" port=\"\(tl.port)\" protocol=\"\(tl.protocol)\""
        }
        if !tl.token.isEmpty {
            attrs += " token=\"\(xmlEscape(tl.token))\""
        }
        attrs += " commandID=\"\(cid)\""

        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
            + "<MediaContainer commandID=\"\(cid)\" location=\"\(location)\">\n"
            + "<Timeline \(attrs) />\n"
            + "<Timeline type=\"music\" state=\"stopped\" location=\"\(location)\" />\n"
            + "<Timeline type=\"photo\" state=\"stopped\" location=\"\(location)\" />\n"
            + "</MediaContainer>"
    }

    private func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func parseQueryString(_ qs: String) -> [String: String] {
        var params: [String: String] = [:]
        for pair in qs.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                let value = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                params[key] = value
            }
        }
        return params
    }

    private func parsePathAndQuery(_ fullPath: String) -> (String, [String: String]) {
        let split = fullPath.split(separator: "?", maxSplits: 1)
        let path = String(split[0])
        var params: [String: String] = [:]
        if split.count > 1 {
            params = parseQueryString(String(split[1]))
        }
        return (path, params)
    }

    private func extractHeader(_ lines: [String], name: String) -> String? {
        let prefix = name.lowercased() + ":"
        for line in lines {
            if line.lowercased().hasPrefix(prefix) {
                return line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func httpResponse(_ status: Int, body: String, contentType: String = "text/xml") -> String {
        let statusText = status == 200 ? "OK" : "Error"
        return """
        HTTP/1.1 \(status) \(statusText)\r
        Content-Type: \(contentType)\r
        Content-Length: \(body.utf8.count)\r
        Access-Control-Allow-Origin: *\r
        Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS\r
        Access-Control-Allow-Headers: *\r
        Access-Control-Expose-Headers: X-Plex-Client-Identifier\r
        Access-Control-Max-Age: 86400\r
        X-Plex-Client-Identifier: \(resourceIdentifier)\r
        X-Plex-Protocol: 1.0\r
        Connection: close\r
        \r
        \(body)
        """
    }

    private func corsResponse() -> String {
        return """
        HTTP/1.1 200 OK\r
        Access-Control-Allow-Origin: *\r
        Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS\r
        Access-Control-Allow-Headers: *\r
        Access-Control-Expose-Headers: X-Plex-Client-Identifier\r
        Access-Control-Max-Age: 86400\r
        X-Plex-Client-Identifier: \(resourceIdentifier)\r
        Content-Length: 0\r
        Connection: close\r
        \r\n
        """
    }
}
