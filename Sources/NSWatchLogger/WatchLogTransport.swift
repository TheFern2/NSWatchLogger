import Foundation

public protocol WatchLogTransport: AnyObject {
    func sendLog(payload: [String: Any])
}
