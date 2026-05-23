import Foundation
import Combine
import Network
import NSWatchLoggerModels

public final class LogServer: ObservableObject, @unchecked Sendable {
    private let lock = NSLock()
    private let httpListener = HTTPListener()
    private let advertiser = BonjourAdvertiser()

    @Published public private(set) var isRunning = false
    @Published public private(set) var connections: [ClientConnection] = []
    @Published public private(set) var isAdvertising = false

    public var onLogReceived: ((LogEntry) -> Void)?

    public init() {}

    public func start(port: UInt16 = BonjourConstants.defaultPort) {
        guard !isRunning else { return }

        httpListener.onLogReceived = { [weak self] entry in
            self?.handleLog(entry)
        }
        httpListener.onClientConnected = { [weak self] client in
            self?.addClient(client)
        }
        httpListener.onClientDisconnected = { [weak self] id in
            self?.removeClient(id)
        }

        advertiser.onStateChanged = { [weak self] advertising in
            DispatchQueue.main.async {
                self?.isAdvertising = advertising
            }
        }

        do {
            try httpListener.start(port: port)
        } catch {
            print("[NSWatchLoggerServer] Failed to start: \(error)")
            httpListener.stop()
            return
        }

        if let httpNW = httpListener.nwListener {
            advertiser.advertise(listener: httpNW)
        }

        DispatchQueue.main.async {
            self.isRunning = true
        }
    }

    public func stop() {
        advertiser.stop()
        httpListener.stop()

        DispatchQueue.main.async {
            self.isRunning = false
            self.connections.removeAll()
        }
    }

    public var httpPort: UInt16? {
        httpListener.nwListener?.port?.rawValue
    }

    private func handleLog(_ entry: LogEntry) {
        updateSessionID(entry)
        onLogReceived?(entry)
    }

    private func addClient(_ client: ClientConnection) {
        DispatchQueue.main.async {
            self.connections.append(client)
        }
    }

    private func removeClient(_ id: UUID) {
        DispatchQueue.main.async {
            self.connections.removeAll { $0.id == id }
        }
    }

    private func updateSessionID(_ entry: LogEntry) {
        DispatchQueue.main.async {
            if let index = self.connections.firstIndex(where: { $0.sessionID == nil || $0.sessionID == entry.sessionID }) {
                if self.connections[index].sessionID == nil {
                    self.connections[index].sessionID = entry.sessionID
                }
            }
        }
    }
}
