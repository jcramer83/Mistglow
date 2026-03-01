import Foundation
import Network

/// Simple UDP sender using POSIX sockets for zero-copy, zero-queue sends.
/// NWConnection is only used for initial DNS resolution / connection setup,
/// then we extract the file descriptor and use sendto() directly.
final class GroovyConnection: @unchecked Sendable {
    private var connection: NWConnection?
    private var socketFD: Int32 = -1
    private var sockAddr: sockaddr_in?
    private let host: String
    private let port: UInt16

    init(host: String, port: UInt16 = GroovyProtocol.udpPort) {
        self.host = host
        self.port = port
    }

    func connect() async throws {
        // Resolve hostname and create raw UDP socket
        let resolved = try await resolveHost(host)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = resolved
        self.sockAddr = addr

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            throw NSError(domain: "GroovyConnection", code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "socket() failed: \(errno)"])
        }

        // Connect the socket so we can use send() instead of sendto()
        let connectResult = withUnsafePointer(to: &self.sockAddr!) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else {
            close(fd)
            throw NSError(domain: "GroovyConnection", code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "connect() failed: \(errno)"])
        }

        // Set send buffer to 2MB to handle burst of frame chunks
        var bufSize: Int32 = 2 * 1024 * 1024
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))

        self.socketFD = fd
        NSLog("UDP connected to %@:%d (fd=%d)", host, port, fd)
    }

    private func resolveHost(_ hostname: String) async throws -> in_addr {
        // Try as numeric IP first
        var addr = in_addr()
        if inet_pton(AF_INET, hostname, &addr) == 1 {
            return addr
        }

        // DNS resolution
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                var hints = addrinfo()
                hints.ai_family = AF_INET
                hints.ai_socktype = SOCK_DGRAM
                var result: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(hostname, nil, &hints, &result)
                if status != 0 {
                    continuation.resume(throwing: NSError(domain: "GroovyConnection", code: Int(status),
                        userInfo: [NSLocalizedDescriptionKey: "DNS resolution failed for \(hostname)"]))
                    return
                }
                defer { freeaddrinfo(result) }
                if let ai = result, ai.pointee.ai_family == AF_INET {
                    let sockaddrIn = ai.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                    continuation.resume(returning: sockaddrIn.sin_addr)
                } else {
                    continuation.resume(throwing: NSError(domain: "GroovyConnection", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "No IPv4 address for \(hostname)"]))
                }
            }
        }
    }

    /// Send data immediately via POSIX send(). No queuing, no completion handlers.
    func send(_ data: Data) {
        guard socketFD >= 0 else { return }
        data.withUnsafeBytes { buf in
            _ = Darwin.send(socketFD, buf.baseAddress!, buf.count, 0)
        }
    }

    /// Same as send() — kept for API compatibility
    func sendSync(_ data: Data) {
        send(data)
    }

    /// Send header + chunked payload. All sends are synchronous POSIX calls —
    /// no internal queue, no completion handlers, no memory accumulation.
    func sendFrame(header: Data, payload: Data, mtu: Int = GroovyProtocol.defaultMTU) {
        guard socketFD >= 0 else { return }

        // Send header
        header.withUnsafeBytes { buf in
            _ = Darwin.send(socketFD, buf.baseAddress!, buf.count, 0)
        }

        // Send payload in MTU-sized chunks
        payload.withUnsafeBytes { buf in
            let base = buf.baseAddress!
            var offset = 0
            while offset < payload.count {
                let len = min(mtu, payload.count - offset)
                _ = Darwin.send(socketFD, base + offset, len, 0)
                offset += len
            }
        }
    }

    func disconnect() {
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
        connection?.cancel()
        connection = nil
    }
}
