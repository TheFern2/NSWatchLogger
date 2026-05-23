import Foundation
import Network
import NSWatchLoggerModels

final class BonjourAdvertiser: @unchecked Sendable {
    private let lock = NSLock()
    private var listener: NWListener?

    var onStateChanged: ((Bool) -> Void)?

    func advertise(listener: NWListener) {
        lock.lock()
        self.listener = listener
        lock.unlock()

        listener.service = NWListener.Service(
            type: BonjourConstants.serviceType
        )

        onStateChanged?(true)
    }

    func stop() {
        lock.lock()
        listener?.service = nil
        listener = nil
        lock.unlock()

        onStateChanged?(false)
    }
}
