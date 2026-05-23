import Foundation
import NSWatchLoggerModels

final class HTTPLogSender: @unchecked Sendable {
    private let lock = NSLock()
    private let session: URLSession
    private var baseURL: URL?
    private let queue: LogQueue
    private let maxRetries = 3
    private var flushTimer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "com.nswatchlogger.http-flush")
    private let batchSize = 10
    private let flushInterval: TimeInterval = 0.1

    var onStatusChanged: ((ConnectionStatus) -> Void)?

    init(queue: LogQueue) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        self.session = URLSession(configuration: config)
        self.queue = queue
    }

    func connect(host: String, port: UInt16) {
        lock.lock()
        self.baseURL = URL(string: "http://\(host):\(port)")
        lock.unlock()

        startFlushTimer()
        onStatusChanged?(.connected)
    }

    func connectToEndpoint(_ endpoint: String, port: UInt16) {
        connect(host: endpoint, port: port)
    }

    func send(_ entry: LogEntry) {
        lock.lock()
        let url = baseURL
        lock.unlock()

        guard url != nil else {
            queue.enqueue(entry)
            return
        }

        queue.enqueue(entry)
        if queue.count >= batchSize {
            flush()
        }
    }

    func disconnect() {
        lock.lock()
        baseURL = nil
        lock.unlock()
        stopFlushTimer()
        onStatusChanged?(.disconnected)
    }

    private func flush() {
        let entries = queue.dequeueAll()
        guard !entries.isEmpty else { return }

        lock.lock()
        guard let baseURL else {
            lock.unlock()
            for entry in entries { queue.enqueue(entry) }
            return
        }
        lock.unlock()

        let path = entries.count == 1
            ? BonjourConstants.httpPathLog
            : BonjourConstants.httpPathBatch

        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            if entries.count == 1 {
                request.httpBody = try LogEntry.jsonEncoder.encode(entries[0])
            } else {
                request.httpBody = try LogEntry.jsonEncoder.encode(entries)
            }
        } catch {
            return
        }

        sendWithRetry(request: request, entries: entries, attempt: 0)
    }

    private func sendWithRetry(request: URLRequest, entries: [LogEntry], attempt: Int) {
        let task = session.dataTask(with: request) { [weak self] _, response, error in
            guard let self else { return }

            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let success = error == nil && (200..<300).contains(statusCode)

            if !success && attempt < self.maxRetries {
                let delay = pow(2.0, Double(attempt))
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                    self.sendWithRetry(request: request, entries: entries, attempt: attempt + 1)
                }
            } else if !success {
                for entry in entries { self.queue.enqueue(entry) }
            }
        }
        task.resume()
    }

    private func startFlushTimer() {
        stopFlushTimer()
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
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
