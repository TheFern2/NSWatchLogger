import Foundation

public enum ConnectionStatus: Sendable {
    case disconnected
    case discovering
    case connecting
    case connected
    case reconnecting
}
