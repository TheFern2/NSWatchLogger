import Foundation

public enum WatchLogger {

    private static let lock = NSLock()
    private static weak var _transport: WatchLogTransport?
    private static var _enabled: Bool = false

    public static func configure(transport: WatchLogTransport, enabled: Bool) {
        lock.lock()
        _transport = transport
        _enabled = enabled
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

    public static func log(_ tag: WatchLogTag, _ level: WatchLogLevel = .debug, _ message: String) {
        print("[\(tag.rawValue.capitalized)] \(message)")

        lock.lock()
        let transport = _transport
        let enabled = _enabled
        lock.unlock()

        guard enabled else { return }

        let payload: [String: Any] = [
            "type": "watchLog",
            "tag": tag.rawValue,
            "level": level.rawValue,
            "message": message
        ]
        transport?.sendLog(payload: payload)
    }
}
