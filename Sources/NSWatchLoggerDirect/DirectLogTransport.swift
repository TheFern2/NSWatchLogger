import Foundation
import NSWatchLogger
import NSWatchLoggerModels
#if os(watchOS)
import WatchKit
#endif

public final class DirectLogTransport: NSObject, WatchLogTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let sessionID: UUID
    private let deviceName: String?
    private let queue: LogQueue
    private let httpSender: HTTPLogSender

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

    private init(host: String, port: UInt16) {
        self.sessionID = UUID()
        self.queue = LogQueue()

        #if os(watchOS)
        self.deviceName = WKInterfaceDevice.current().name
        #else
        self.deviceName = nil
        #endif

        let sender = HTTPLogSender(queue: queue)
        self.httpSender = sender

        super.init()

        sender.onStatusChanged = { [weak self] status in
            self?.connectionStatus = status
        }

        connectionStatus = .connecting
        sender.connect(host: host, port: port)
    }

    public static func create(
        host: String,
        port: UInt16 = BonjourConstants.defaultPort
    ) -> DirectLogTransport {
        DirectLogTransport(host: host, port: port)
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

        httpSender.send(entry)
    }

    // MARK: - Connection

    public func disconnect() {
        httpSender.disconnect()
        connectionStatus = .disconnected
    }
}
