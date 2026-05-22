import Foundation
import Network
import NSWatchLoggerModels

final class BonjourDiscovery: @unchecked Sendable {
    private let lock = NSLock()
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "com.nswatchlogger.bonjour-discovery")

    var onServiceFound: ((NWEndpoint) -> Void)?
    var onStateChanged: ((NWBrowser.State) -> Void)?

    func start() {
        lock.lock()
        defer { lock.unlock() }

        stop_locked()

        let descriptor = NWBrowser.Descriptor.bonjour(
            type: BonjourConstants.serviceType,
            domain: nil
        )
        let browser = NWBrowser(for: descriptor, using: .tcp)

        browser.stateUpdateHandler = { [weak self] state in
            self?.onStateChanged?(state)
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            if let result = results.first {
                self.onServiceFound?(result.endpoint)
            }
        }

        browser.start(queue: queue)
        self.browser = browser
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        stop_locked()
    }

    private func stop_locked() {
        browser?.cancel()
        browser = nil
    }
}
