import Foundation
import Network
import NSWatchLogger
import NSWatchLoggerModels
#if os(watchOS)
import WatchKit
#endif

public enum TransportMode: Sendable {
    case http
    case webSocket
}

public final class DirectLogTransport: NSObject, WatchLogTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let mode: TransportMode
    private let sessionID: UUID
    private let deviceName: String?
    private let queue: LogQueue

    private var httpSender: HTTPLogSender?
    private var wsSender: WebSocketLogSender?
    private var discovery: BonjourDiscovery?
    private var _connectionStatus: ConnectionStatus = .disconnected
    private var statusHandler: ((ConnectionStatus) -> Void)?

    public private(set) var connectionStatus: ConnectionStatus {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _connectionStatus
        }
        set {
            lock.lock()
            _connectionStatus = newValue
            let handler = statusHandler
            lock.unlock()
            handler?(newValue)
        }
    }

    public var onConnectionStatusChanged: ((ConnectionStatus) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return statusHandler
        }
        set {
            lock.lock()
            statusHandler = newValue
            lock.unlock()
        }
    }

    private init(mode: TransportMode, host: String?, port: UInt16) {
        self.mode = mode
        self.sessionID = UUID()
        self.queue = LogQueue()

        #if os(watchOS)
        self.deviceName = WKInterfaceDevice.current().name
        #else
        self.deviceName = nil
        #endif

        super.init()

        switch mode {
        case .http:
            let sender = HTTPLogSender(queue: queue)
            sender.onStatusChanged = { [weak self] status in
                self?.connectionStatus = status
            }
            self.httpSender = sender
        case .webSocket:
            let sender = WebSocketLogSender(queue: queue)
            sender.onStatusChanged = { [weak self] status in
                self?.connectionStatus = status
            }
            self.wsSender = sender
        }

        if let host {
            connectToHost(host, port: port)
        } else {
            startDiscovery(port: port)
        }
    }

    public static func create(
        mode: TransportMode,
        host: String? = nil,
        port: UInt16 = BonjourConstants.defaultPort
    ) -> DirectLogTransport {
        DirectLogTransport(mode: mode, host: host, port: port)
    }

    // MARK: - WatchLogTransport

    public func sendLog(payload: [String: Any]) {
        let tag = payload["tag"] as? String ?? "unknown"
        let level = payload["level"] as? String ?? "debug"
        let message = payload["message"] as? String ?? ""

        let entry = LogEntry(
            tag: tag,
            level: level,
            message: message,
            sessionID: sessionID,
            deviceName: deviceName
        )

        switch mode {
        case .http:
            httpSender?.send(entry)
        case .webSocket:
            wsSender?.send(entry)
        }
    }

    // MARK: - Connection

    public func disconnect() {
        discovery?.stop()
        httpSender?.disconnect()
        wsSender?.disconnect()
        connectionStatus = .disconnected
    }

    private func connectToHost(_ host: String, port: UInt16) {
        connectionStatus = .connecting
        switch mode {
        case .http:
            httpSender?.connect(host: host, port: port)
        case .webSocket:
            let wsPort = port + BonjourConstants.wsPortOffset
            wsSender?.connect(host: host, port: wsPort)
        }
    }

    private func startDiscovery(port: UInt16) {
        connectionStatus = .discovering
        let disc = BonjourDiscovery()
        disc.onServiceFound = { [weak self] endpoint in
            guard let self else { return }
            self.discovery?.stop()
            self.resolveAndConnect(endpoint: endpoint, port: port)
        }
        disc.start()
        self.discovery = disc
    }

    private func resolveAndConnect(endpoint: NWEndpoint, port: UInt16) {
        connectionStatus = .connecting
        let resolver = NWConnection(to: endpoint, using: .tcp)
        resolver.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                defer { resolver.cancel() }
                guard let resolved = resolver.currentPath?.remoteEndpoint,
                      case .hostPort(let host, _) = resolved else {
                    self.connectionStatus = .disconnected
                    return
                }
                let hostString = "\(host)"
                switch self.mode {
                case .http:
                    var httpHost = hostString
                    if hostString.contains(":") {
                        httpHost = "[\(hostString)]"
                    }
                    self.httpSender?.connect(host: httpHost, port: port)
                case .webSocket:
                    let wsPort = port + BonjourConstants.wsPortOffset
                    self.wsSender?.connect(host: hostString, port: wsPort)
                }
            case .failed:
                resolver.cancel()
                self.connectionStatus = .disconnected
            default:
                break
            }
        }
        resolver.start(queue: DispatchQueue(label: "com.nswatchlogger.resolver"))
    }
}
