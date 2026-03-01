import Foundation
import Network

/// Simple UDP sender - NOT an actor, sends are synchronous on caller's queue
final class GroovyConnection: @unchecked Sendable {
    private var connection: NWConnection?
    private let host: String
    private let port: UInt16
    private let sendGroup = DispatchGroup()

    init(host: String, port: UInt16 = GroovyProtocol.udpPort) {
        self.host = host
        self.port = port
    }

    func connect() async throws {
        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let params = NWParameters.udp

        let conn = NWConnection(host: nwHost, port: nwPort, using: params)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.resume()
                case .failed(let error):
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .userInteractive))
        }
        self.connection = conn
    }

    /// Fire-and-forget send
    func send(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }

    /// Send data and wait for it to be processed (for commands that need ordering)
    func sendSync(_ data: Data) {
        guard let conn = connection else { return }
        let sem = DispatchSemaphore(value: 0)
        conn.send(content: data, completion: .contentProcessed { _ in
            sem.signal()
        })
        sem.wait()
    }

    /// Send a frame: header + chunked payload, all sent in order
    func sendFrame(header: Data, payload: Data, mtu: Int = GroovyProtocol.defaultMTU) {
        guard let conn = connection else { return }

        // Send header
        conn.send(content: header, completion: .contentProcessed { _ in })

        // Send payload in chunks
        var offset = 0
        while offset < payload.count {
            let end = min(offset + mtu, payload.count)
            let chunk = Data(payload[offset..<end])
            conn.send(content: chunk, completion: .contentProcessed { _ in })
            offset = end
        }
    }


    func disconnect() {
        connection?.cancel()
        connection = nil
    }
}
