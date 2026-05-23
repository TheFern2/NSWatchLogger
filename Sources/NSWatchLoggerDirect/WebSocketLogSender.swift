import Foundation
import Network
import NSWatchLoggerModels

final class WebSocketLogSender: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var webSocketTask: URLSessionWebSocketTask?
    private let queue: LogQueue
    private let networkQueue = DispatchQueue(label: "com.nswatchlogger.websocket")
    private var host: String?
    private var port: UInt16 = 0
    private var reconnectAttempt = 0
    private let maxReconnectDelay: TimeInterval = 30
    private var heartbeatTimer: DispatchSourceTimer?
    private let heartbeatInterval: TimeInterval = 15
    private var intentionalDisconnect = false

    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }()

    var onStatusChanged: ((ConnectionStatus) -> Void)?

    init(queue: LogQueue) {
        self.queue = queue
        super.init()
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

        onStatusChanged?(.connecting)
        let params = NWParameters.tcp
        let resolver = NWConnection(to: endpoint, using: params)
        resolver.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let resolved = resolver.currentPath?.remoteEndpoint,
                   case .hostPort(let host, let port) = resolved {
                    resolver.cancel()
                    self?.connect(host: "\(host)", port: port.rawValue)
                } else {
                    resolver.cancel()
                    self?.onStatusChanged?(.disconnected)
                }
            case .failed:
                resolver.cancel()
                self?.onStatusChanged?(.disconnected)
            default:
                break
            }
        }
        resolver.start(queue: networkQueue)
    }

    func send(_ entry: LogEntry) {
        guard let data = try? LogEntry.jsonEncoder.encode(entry),
              let text = String(data: data, encoding: .utf8) else { return }

        lock.lock()
        let task = webSocketTask
        lock.unlock()

        guard let task, task.state == .running else {
            queue.enqueue(entry)
            return
        }

        task.send(.string(text)) { [weak self] error in
            if error != nil {
                self?.queue.enqueue(entry)
            }
        }
    }

    func disconnect() {
        lock.lock()
        intentionalDisconnect = true
        let task = webSocketTask
        webSocketTask = nil
        lock.unlock()

        stopHeartbeat()
        task?.cancel(with: .goingAway, reason: nil)
        onStatusChanged?(.disconnected)
    }

    private func establishConnection(host: String, port: UInt16) {
        var urlHost = host
        if host.contains(":") {
            urlHost = "[\(host)]"
        }
        guard let url = URL(string: "ws://\(urlHost):\(port)") else {
            onStatusChanged?(.disconnected)
            return
        }

        let task = session.webSocketTask(with: url)

        lock.lock()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = task
        lock.unlock()

        onStatusChanged?(.connecting)
        task.resume()
    }

    private func receiveLoop() {
        lock.lock()
        let task = webSocketTask
        lock.unlock()

        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.receiveLoop()
            case .failure:
                self.handleDisconnect()
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
        lock.lock()
        guard webSocketTask != nil else {
            lock.unlock()
            return
        }
        webSocketTask = nil
        let shouldReconnect = !intentionalDisconnect
        let host = self.host
        let port = self.port
        reconnectAttempt += 1
        let attempt = reconnectAttempt
        lock.unlock()

        stopHeartbeat()

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
        let task = webSocketTask
        lock.unlock()

        task?.sendPing { [weak self] error in
            if error != nil {
                self?.handleDisconnect()
            }
        }
    }
}

extension WebSocketLogSender: URLSessionWebSocketDelegate {
    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        lock.lock()
        reconnectAttempt = 0
        lock.unlock()

        onStatusChanged?(.connected)
        startHeartbeat()
        flushQueue()
        receiveLoop()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        handleDisconnect()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        if error != nil {
            handleDisconnect()
        }
    }
}
