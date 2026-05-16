import Foundation

public enum WatchLogTag: Sendable {
    case network
    case workout
    case service
    case debug
    case custom(String)

    public var rawValue: String {
        switch self {
        case .network: return "network"
        case .workout: return "workout"
        case .service: return "service"
        case .debug: return "debug"
        case .custom(let value): return value
        }
    }
}
