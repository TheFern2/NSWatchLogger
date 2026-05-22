import Foundation
import Network
import NSWatchLoggerModels

final class WebSocketListener: @unchecked Sendable {
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private let queue = DispatchQueue(label: "com.nswatchlogger.ws-listener")

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

        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true

        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        let listener = try NWListener(using: params, on: nwPort)

        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                print("[NSWatchLoggerServer] WebSocket listener failed: \(error)")
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

    var activeConnectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return connections.count
    }

    private func handleConnection(_ connection: NWConnection) {
        let clientID = UUID()
        let endpoint = describeEndpoint(connection.endpoint)
        let client = ClientConnection(
            id: clientID,
            remoteEndpoint: endpoint,
            transportType: .webSocket
        )

        lock.lock()
        connections[clientID] = connection
        lock.unlock()

        onClientConnected?(client)

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receiveLoop(connection, clientID: clientID)
            case .failed, .cancelled:
                self?.removeConnection(clientID)
            default:
                break
            }
        }

        connection.start(queue: queue)
    }

    private func receiveLoop(_ connection: NWConnection, clientID: UUID) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }

            if let error {
                print("[NSWatchLoggerServer] WebSocket receive error: \(error)")
                self.removeConnection(clientID)
                return
            }

            if let data, !data.isEmpty, self.isTextFrame(context: context) {
                do {
                    let entry = try LogEntry.jsonDecoder.decode(LogEntry.self, from: data)
                    self.onLogReceived?(entry)
                } catch {
                    print("[NSWatchLoggerServer] Failed to decode log entry: \(error)")
                }
            }

            self.receiveLoop(connection, clientID: clientID)
        }
    }

    private func isTextFrame(context: NWConnection.ContentContext?) -> Bool {
        guard let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata else {
            return false
        }
        return metadata.opcode == .text
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
