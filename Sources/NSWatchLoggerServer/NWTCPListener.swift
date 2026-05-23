import Foundation
import Network
import NSWatchLoggerModels

final class NWTCPListener: @unchecked Sendable {
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private let queue = DispatchQueue(label: "com.nswatchlogger.nwtcp-listener")

    var onLogReceived: ((LogEntry) -> Void)?
    var onClientConnected: ((ClientConnection) -> Void)?
    var onClientDisconnected: ((UUID) -> Void)?

    var nwListener: NWListener? {
        lock.lock()
        defer { lock.unlock() }
        return listener
    }

    func start(port: UInt16) throws {
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let listener = try NWListener(using: .tcp, on: nwPort)

        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                print("[NSWatchLoggerServer] TCP listener failed: \(error)")
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener.start(queue: queue)

        lock.lock()
        self.listener = listener
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let l = listener
        listener = nil
        let conns = connections
        connections.removeAll()
        lock.unlock()

        for (_, conn) in conns {
            conn.cancel()
        }
        l?.cancel()
    }

    private func handleConnection(_ connection: NWConnection) {
        let clientID = UUID()
        let endpoint = describeEndpoint(connection.endpoint)
        let client = ClientConnection(
            id: clientID,
            remoteEndpoint: endpoint,
            transportType: .tcp
        )

        lock.lock()
        connections[clientID] = connection
        lock.unlock()

        onClientConnected?(client)

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receiveFrames(connection, clientID: clientID, buffer: Data())
            case .failed, .cancelled:
                self?.removeConnection(clientID)
            default:
                break
            }
        }

        connection.start(queue: queue)
    }

    // Frame format: [1 byte type][4 bytes big-endian UInt32 length][JSON payload]
    // type 0x01 = single LogEntry, type 0x02 = [LogEntry] array
    private func receiveFrames(_ connection: NWConnection, clientID: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            var accumulated = buffer
            if let data, !data.isEmpty {
                accumulated.append(data)
            }

            accumulated = self.processFrames(accumulated)

            if error != nil || isComplete {
                self.removeConnection(clientID)
                return
            }

            self.receiveFrames(connection, clientID: clientID, buffer: accumulated)
        }
    }

    private func processFrames(_ data: Data) -> Data {
        var remaining = data
        let headerSize = 5

        while remaining.count >= headerSize {
            let type = remaining[remaining.startIndex]
            let lengthBytes = remaining[remaining.index(remaining.startIndex, offsetBy: 1)..<remaining.index(remaining.startIndex, offsetBy: 5)]
            let length = UInt32(bigEndian: lengthBytes.withUnsafeBytes { $0.load(as: UInt32.self) })
            let totalFrameSize = headerSize + Int(length)

            guard remaining.count >= totalFrameSize else { break }

            let payloadStart = remaining.index(remaining.startIndex, offsetBy: headerSize)
            let payloadEnd = remaining.index(remaining.startIndex, offsetBy: totalFrameSize)
            let payload = remaining[payloadStart..<payloadEnd]

            decodePayload(Data(payload), type: type)

            remaining = Data(remaining[payloadEnd...])
        }

        return remaining
    }

    private func decodePayload(_ data: Data, type: UInt8) {
        do {
            if type == 0x01 {
                let entry = try LogEntry.jsonDecoder.decode(LogEntry.self, from: data)
                onLogReceived?(entry)
            } else {
                let entries = try LogEntry.jsonDecoder.decode([LogEntry].self, from: data)
                for entry in entries {
                    onLogReceived?(entry)
                }
            }
        } catch {
            print("[NSWatchLoggerServer] TCP decode error: \(error)")
        }
    }

    private func removeConnection(_ clientID: UUID) {
        lock.lock()
        let conn = connections.removeValue(forKey: clientID)
        lock.unlock()

        conn?.cancel()
        onClientDisconnected?(clientID)
    }

    private func describeEndpoint(_ endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .hostPort(let host, let port):
            return "\(host):\(port)"
        default:
            return endpoint.debugDescription
        }
    }
}
