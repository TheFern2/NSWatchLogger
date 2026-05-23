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
    case tcp
}

public final class DirectLogTransport: NSObject, WatchLogTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let mode: TransportMode
    private let sessionID: UUID
    private let deviceName: String?
    private let queue: LogQueue

    private var httpSender: HTTPLogSender?
    private var wsSender: WebSocketLogSender?
    private var tcpSender: NWTCPLogSender?
    private var discovery: BonjourDiscovery?
    private var activeResolver: BonjourResolver?
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
        case .tcp:
            let sender = NWTCPLogSender(queue: queue)
            sender.onStatusChanged = { [weak self] status in
                self?.connectionStatus = status
            }
            self.tcpSender = sender
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
        case .tcp:
            tcpSender?.send(entry)
        }
    }

    // MARK: - Connection

    public func disconnect() {
        discovery?.stop()
        httpSender?.disconnect()
        wsSender?.disconnect()
        tcpSender?.disconnect()
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
        case .tcp:
            let tcpPort = port + BonjourConstants.tcpPortOffset
            tcpSender?.connect(host: host, port: tcpPort)
        }
    }

    private func startDiscovery(port: UInt16) {
        connectionStatus = .discovering
        let disc = BonjourDiscovery()
        disc.onServiceFound = { [weak self] endpoint in
            guard let self else { return }
            self.discovery?.stop()
            switch self.mode {
            case .http:
                self.connectionStatus = .connecting
                self.resolveEndpoint(endpoint) { host in
                    if let host {
                        self.httpSender?.connect(host: host, port: port)
                    } else {
                        self.connectionStatus = .disconnected
                    }
                }
            case .webSocket:
                self.wsSender?.connectToEndpoint(endpoint)
            case .tcp:
                self.connectionStatus = .connecting
                self.resolveEndpoint(endpoint) { host in
                    if let host {
                        let tcpPort = port + BonjourConstants.tcpPortOffset
                        self.tcpSender?.connect(host: host, port: tcpPort)
                    } else {
                        self.connectionStatus = .disconnected
                    }
                }
            }
        }
        disc.start()
        self.discovery = disc
    }

    private func resolveEndpoint(_ endpoint: NWEndpoint, completion: @escaping (String?) -> Void) {
        guard case .service(let name, let type, let domain, _) = endpoint else {
            completion(nil)
            return
        }

        let resolver = BonjourResolver()
        self.activeResolver = resolver
        resolver.resolve(name: name, type: type, domain: domain) { [weak self] host in
            self?.activeResolver = nil
            completion(host)
        }
    }
}
