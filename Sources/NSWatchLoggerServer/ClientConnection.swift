import Foundation

public struct ClientConnection: Identifiable, Sendable {
    public let id: UUID
    public let remoteEndpoint: String
    public let connectedAt: Date
    public var sessionID: UUID?

    public init(
        id: UUID = UUID(),
        remoteEndpoint: String,
        connectedAt: Date = Date(),
        sessionID: UUID? = nil
    ) {
        self.id = id
        self.remoteEndpoint = remoteEndpoint
        self.connectedAt = connectedAt
        self.sessionID = sessionID
    }
}
