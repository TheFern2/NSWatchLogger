import Foundation
import NSWatchLoggerModels

final class LogQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [LogEntry]
    private let capacity: Int

    init(capacity: Int = 500) {
        self.capacity = capacity
        self.buffer = []
        self.buffer.reserveCapacity(min(capacity, 64))
    }

    func enqueue(_ entry: LogEntry) {
        lock.lock()
        defer { lock.unlock() }
        if buffer.count >= capacity {
            buffer.removeFirst()
        }
        buffer.append(entry)
    }

    func dequeueAll() -> [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        let entries = buffer
        buffer.removeAll(keepingCapacity: true)
        return entries
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffer.count
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return buffer.isEmpty
    }
}
