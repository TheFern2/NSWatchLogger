import Foundation

public enum TransportType: String, Sendable {
    case http
    case webSocket
    case tcp
}

public struct ClientConnection: Identifiable, Sendable {
    public let id: UUID
    public let remoteEndpoint: String
    public let connectedAt: Date
    public var sessionID: UUID?
    public let transportType: TransportType

    public init(
        id: UUID = UUID(),
        remoteEndpoint: String,
        connectedAt: Date = Date(),
        sessionID: UUID? = nil,
        transportType: TransportType
    ) {
        self.id = id
        self.remoteEndpoint = remoteEndpoint
        self.connectedAt = connectedAt
        self.sessionID = sessionID
        self.transportType = transportType
    }
}
