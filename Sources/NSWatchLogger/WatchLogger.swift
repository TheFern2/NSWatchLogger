import Foundation

public enum WatchLogger {

    private static let lock = NSLock()
    private static weak var _transport: WatchLogTransport?
    private static var _enabled: Bool = false
    private static var _minimumLevel: WatchLogLevel = .debug

    public static func configure(
        transport: WatchLogTransport,
        enabled: Bool,
        minimumLevel: WatchLogLevel = .debug
    ) {
        lock.lock()
        _transport = transport
        _enabled = enabled
        _minimumLevel = minimumLevel
        lock.unlock()
    }

    public static var isEnabled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _enabled
        }
        set {
            lock.lock()
            _enabled = newValue
            lock.unlock()
        }
    }

    public static var minimumLevel: WatchLogLevel {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _minimumLevel
        }
        set {
            lock.lock()
            _minimumLevel = newValue
            lock.unlock()
        }
    }

    public static func log(_ tag: WatchLogTag, _ level: WatchLogLevel = .debug, _ message: String) {
        lock.lock()
        let transport = _transport
        let enabled = _enabled
        let minLevel = _minimumLevel
        lock.unlock()

        guard enabled, level >= minLevel else { return }

        print("[\(tag.rawValue.capitalized)] \(message)")

        let payload: [String: Any] = [
            "type": "watchLog",
            "tag": tag.rawValue,
            "level": level.rawValue,
            "message": message
        ]
        transport?.sendLog(payload: payload)
    }
}
