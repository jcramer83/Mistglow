import Foundation

final class PlexGDMAdvertiser: @unchecked Sendable {
    private let companionPort: UInt16
    private let resourceIdentifier: String
    private var socket: Int32 = -1
    private var readSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.mistglow.plex.gdm", qos: .utility)

    init(companionPort: UInt16 = 3005, resourceIdentifier: String) {
        self.companionPort = companionPort
        self.resourceIdentifier = resourceIdentifier
    }

    func start() {
        queue.async { [weak self] in
            self?.setupSocket()
        }
    }

    func stop() {
        readSource?.cancel()
        readSource = nil
        if socket >= 0 {
            Darwin.close(socket)
            socket = -1
        }
    }

    private func setupSocket() {
        // Create UDP socket
        socket = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socket >= 0 else { return }

        // Allow address reuse
        var reuse: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(socket, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))

        // Bind to port 32412 (GDM player discovery port)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(32412).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(socket, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(socket)
            socket = -1
            return
        }

        // Join multicast group 239.0.0.250
        var mreq = ip_mreq()
        mreq.imr_multiaddr.s_addr = inet_addr("239.0.0.250")
        mreq.imr_interface.s_addr = INADDR_ANY.bigEndian
        setsockopt(socket, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size))

        // Set up dispatch source for reading
        let source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: queue)
        source.setEventHandler { [weak self] in
            self?.handleRead()
        }
        source.setCancelHandler { [weak self] in
            if let s = self?.socket, s >= 0 {
                Darwin.close(s)
                self?.socket = -1
            }
        }
        source.resume()
        self.readSource = source
    }

    private func handleRead() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var senderAddr = sockaddr_in()
        var senderLen = socklen_t(MemoryLayout<sockaddr_in>.size)

        let bytesRead = withUnsafeMutablePointer(to: &senderAddr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                recvfrom(socket, &buffer, buffer.count, 0, sockPtr, &senderLen)
            }
        }

        guard bytesRead > 0 else { return }

        let message = String(bytes: buffer.prefix(bytesRead), encoding: .utf8) ?? ""
        guard message.contains("M-SEARCH") else { return }

        // Build GDM response
        let response = buildResponse()
        guard let responseData = response.data(using: .utf8) else { return }

        // Send response back to the sender
        responseData.withUnsafeBytes { ptr in
            withUnsafeMutablePointer(to: &senderAddr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    _ = sendto(socket, ptr.baseAddress!, responseData.count, 0, sockPtr, senderLen)
                }
            }
        }
    }

    private func buildResponse() -> String {
        let timestamp = Int(Date().timeIntervalSince1970)
        return [
            "HTTP/1.0 200 OK",
            "Content-Type: plex/media-player",
            "Name: MiSTer",
            "Port: \(companionPort)",
            "Product: Mistglow",
            "Protocol: plex",
            "Protocol-Capabilities: timeline,playback,navigation,playqueues",
            "Protocol-Version: 1",
            "Resource-Identifier: \(resourceIdentifier)",
            "Updated-At: \(timestamp)",
            "Version: 1.0",
            "Device-Class: stb",
            "",
        ].joined(separator: "\r\n")
    }
}
