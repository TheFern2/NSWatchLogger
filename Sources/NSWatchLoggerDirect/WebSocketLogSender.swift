import Foundation
import Network
import NSWatchLoggerModels

final class WebSocketLogSender: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NWConnection?
    private let queue: LogQueue
    private let networkQueue = DispatchQueue(label: "com.nswatchlogger.websocket")
    private var host: String?
    private var port: UInt16 = 0
    private var reconnectAttempt = 0
    private let maxReconnectDelay: TimeInterval = 30
    private var heartbeatTimer: DispatchSourceTimer?
    private let heartbeatInterval: TimeInterval = 15
    private var intentionalDisconnect = false

    var onStatusChanged: ((ConnectionStatus) -> Void)?

    init(queue: LogQueue) {
        self.queue = queue
    }

    func connect(host: String, port: UInt16) {
        lock.lock()
        self.host = host
        self.port = port
        self.intentionalDisconnect = false
        lock.unlock()

        establishConnection(host: host, port: port)
    }

    func connectToEndpoint(_ endpoint: NWEndpoint) {
        lock.lock()
        self.intentionalDisconnect = false
        lock.unlock()

        let ws = NWProtocolWebSocket.Options()
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)

        let conn = NWConnection(to: endpoint, using: params)
        startConnection(conn)
    }

    func send(_ entry: LogEntry) {
        guard let data = try? LogEntry.jsonEncoder.encode(entry) else { return }

        lock.lock()
        let conn = connection
        lock.unlock()

        guard let conn, conn.state == .ready else {
            queue.enqueue(entry)
            return
        }

        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(
            identifier: "logEntry",
            metadata: [metadata]
        )

        conn.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
            if error != nil {
                self?.queue.enqueue(entry)
            }
        })
    }

    func disconnect() {
        lock.lock()
        intentionalDisconnect = true
        let conn = connection
        connection = nil
        lock.unlock()

        stopHeartbeat()
        conn?.cancel()
        onStatusChanged?(.disconnected)
    }

    private func establishConnection(host: String, port: UInt16) {
        let ws = NWProtocolWebSocket.Options()
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)

        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let conn = NWConnection(host: nwHost, port: nwPort, using: params)
        startConnection(conn)
    }

    private func startConnection(_ conn: NWConnection) {
        lock.lock()
        connection?.cancel()
        connection = conn
        lock.unlock()

        onStatusChanged?(.connecting)

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.lock.lock()
                self.reconnectAttempt = 0
                self.lock.unlock()
                self.onStatusChanged?(.connected)
                self.startHeartbeat()
                self.flushQueue()
                self.receiveLoop(conn)
            case .failed:
                self.handleDisconnect()
            case .waiting:
                self.onStatusChanged?(.reconnecting)
            default:
                break
            }
        }

        conn.start(queue: networkQueue)
    }

    private func receiveLoop(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] _, _, _, error in
            guard let self else { return }
            if error == nil {
                self.receiveLoop(conn)
            }
        }
    }

    private func flushQueue() {
        let entries = queue.dequeueAll()
        for entry in entries {
            send(entry)
        }
    }

    private func handleDisconnect() {
        stopHeartbeat()

        lock.lock()
        let shouldReconnect = !intentionalDisconnect
        let host = self.host
        let port = self.port
        reconnectAttempt += 1
        let attempt = reconnectAttempt
        lock.unlock()

        guard shouldReconnect, let host else {
            onStatusChanged?(.disconnected)
            return
        }

        onStatusChanged?(.reconnecting)

        let delay = min(pow(2.0, Double(attempt - 1)), maxReconnectDelay)
        networkQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.establishConnection(host: host, port: port)
        }
    }

    private func startHeartbeat() {
        stopHeartbeat()
        let timer = DispatchSource.makeTimerSource(queue: networkQueue)
        timer.schedule(deadline: .now() + heartbeatInterval, repeating: heartbeatInterval)
        timer.setEventHandler { [weak self] in
            self?.sendPing()
        }
        timer.resume()

        lock.lock()
        heartbeatTimer = timer
        lock.unlock()
    }

    private func stopHeartbeat() {
        lock.lock()
        let timer = heartbeatTimer
        heartbeatTimer = nil
        lock.unlock()
        timer?.cancel()
    }

    private func sendPing() {
        lock.lock()
        let conn = connection
        lock.unlock()

        guard let conn, conn.state == .ready else { return }

        let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
        metadata.setPongHandler(networkQueue) { _ in }
        let context = NWConnection.ContentContext(
            identifier: "ping",
            metadata: [metadata]
        )
        conn.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }
}
