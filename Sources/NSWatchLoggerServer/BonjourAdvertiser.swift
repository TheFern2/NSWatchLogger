import Foundation
import Network
import NSWatchLoggerModels

final class BonjourAdvertiser: @unchecked Sendable {
    private let lock = NSLock()
    private var httpListener: NWListener?
    private var wsListener: NWListener?
    private var tcpListener: NWListener?

    var onStateChanged: ((Bool) -> Void)?

    func advertise(httpListener: NWListener, wsListener: NWListener, tcpListener: NWListener) {
        lock.lock()
        self.httpListener = httpListener
        self.wsListener = wsListener
        self.tcpListener = tcpListener
        lock.unlock()

        var httpTXT = NWTXTRecord()
        httpTXT[TXTKey.transport] = "http"
        httpListener.service = NWListener.Service(
            type: BonjourConstants.serviceType,
            txtRecord: httpTXT
        )

        var wsTXT = NWTXTRecord()
        wsTXT[TXTKey.transport] = "websocket"
        wsListener.service = NWListener.Service(
            type: BonjourConstants.serviceType,
            txtRecord: wsTXT
        )

        var tcpTXT = NWTXTRecord()
        tcpTXT[TXTKey.transport] = "tcp"
        tcpListener.service = NWListener.Service(
            type: BonjourConstants.serviceType,
            txtRecord: tcpTXT
        )

        onStateChanged?(true)
    }

    func stop() {
        lock.lock()
        httpListener?.service = nil
        wsListener?.service = nil
        tcpListener?.service = nil
        httpListener = nil
        wsListener = nil
        tcpListener = nil
        lock.unlock()

        onStateChanged?(false)
    }
}

private enum TXTKey {
    static let transport = "transport"
}

private extension NWTXTRecord {
    subscript(key: String) -> String? {
        get {
            guard let entry = self.getEntry(for: key) else { return nil }
            if case .string(let value) = entry {
                return value
            }
            return nil
        }
        set {
            if let newValue {
                self.setEntry(.string(newValue), for: key)
            } else {
                self.removeEntry(key: key)
            }
        }
    }
}
