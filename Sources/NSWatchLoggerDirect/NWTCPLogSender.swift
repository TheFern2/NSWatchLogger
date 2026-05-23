import Foundation
import Network
import NSWatchLoggerModels

final class NWTCPLogSender: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NWConnection?
    private let queue: LogQueue
    private let networkQueue = DispatchQueue(label: "com.nswatchlogger.nwtcp")
    private var host: String?
    private var port: UInt16 = 0
    private var reconnectAttempt = 0
    private let maxReconnectDelay: TimeInterval = 30
    private var intentionalDisconnect = false
    private var flushTimer: DispatchSourceTimer?
    private let flushInterval: TimeInterval = 0.1
    private let batchSize = 10

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
        queue.enqueue(entry)
        if queue.count >= batchSize {
            flush()
        }
    }

    func disconnect() {
        lock.lock()
        intentionalDisconnect = true
        let conn = connection
        connection = nil
        lock.unlock()

        stopFlushTimer()
        conn?.cancel()
        onStatusChanged?(.disconnected)
    }

    private func establishConnection(host: String, port: UInt16) {
        lock.lock()
        connection?.cancel()
        lock.unlock()

        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let conn = NWConnection(host: nwHost, port: nwPort, using: .tcp)

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.lock.lock()
                self.reconnectAttempt = 0
                self.lock.unlock()
                self.onStatusChanged?(.connected)
                self.startFlushTimer()
                self.flush()
            case .failed, .cancelled:
                self.stopFlushTimer()
                self.handleDisconnect()
            case .waiting:
                self.onStatusChanged?(.reconnecting)
            default:
                break
            }
        }

        lock.lock()
        connection = conn
        lock.unlock()

        onStatusChanged?(.connecting)
        conn.start(queue: networkQueue)
    }

    private func flush() {
        let entries = queue.dequeueAll()
        guard !entries.isEmpty else { return }

        lock.lock()
        let conn = connection
        lock.unlock()

        guard let conn else {
            for entry in entries { queue.enqueue(entry) }
            return
        }

        do {
            let payload: Data
            if entries.count == 1 {
                payload = try LogEntry.jsonEncoder.encode(entries[0])
            } else {
                payload = try LogEntry.jsonEncoder.encode(entries)
            }

            var frame = Data(capacity: 5 + payload.count)
            let type: UInt8 = entries.count == 1 ? 0x01 : 0x02
            frame.append(type)
            var length = UInt32(payload.count).bigEndian
            frame.append(Data(bytes: &length, count: 4))
            frame.append(payload)

            conn.send(content: frame, completion: .contentProcessed { [weak self] error in
                if error != nil {
                    for entry in entries { self?.queue.enqueue(entry) }
                }
            })
        } catch {
            return
        }
    }

    private func handleDisconnect() {
        lock.lock()
        connection?.cancel()
        connection = nil
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

    private func startFlushTimer() {
        stopFlushTimer()
        let timer = DispatchSource.makeTimerSource(queue: networkQueue)
        timer.schedule(deadline: .now() + flushInterval, repeating: flushInterval)
        timer.setEventHandler { [weak self] in
            self?.flush()
        }
        timer.resume()

        lock.lock()
        flushTimer = timer
        lock.unlock()
    }

    private func stopFlushTimer() {
        lock.lock()
        let timer = flushTimer
        flushTimer = nil
        lock.unlock()
        timer?.cancel()
    }
}
