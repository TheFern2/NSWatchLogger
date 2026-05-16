import Foundation

public enum WatchLogRelay {

    private static let lock = NSLock()
    private static var _sink: WatchLogSink?

    public static func configure(sink: WatchLogSink) {
        lock.lock()
        _sink = sink
        lock.unlock()
    }

    public static func process(_ message: [String: Any]) {
        guard let tag = message["tag"] as? String,
              let level = message["level"] as? String,
              let text = message["message"] as? String else { return }

        lock.lock()
        let sink = _sink
        lock.unlock()

        sink?.log(domain: tag, level: level, message: text)
    }
}
