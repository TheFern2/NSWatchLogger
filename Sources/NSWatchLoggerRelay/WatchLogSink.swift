import Foundation

public protocol WatchLogSink {
    func log(domain: String, level: String, message: String)
}
