import Foundation

public enum WatchLogLevel: String, Sendable, Comparable {
    case debug
    case info
    case warning
    case error

    private var sortOrder: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warning: return 2
        case .error: return 3
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}
