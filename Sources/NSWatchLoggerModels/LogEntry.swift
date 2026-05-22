import Foundation

public struct LogEntry: Codable, Identifiable, Sendable, Hashable, Comparable {
    public static func < (lhs: LogEntry, rhs: LogEntry) -> Bool {
        lhs.timestamp < rhs.timestamp
    }

    public let id: UUID
    public let timestamp: Date
    public let tag: String
    public let level: String
    public let message: String
    public let sessionID: UUID
    public let deviceName: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        tag: String,
        level: String,
        message: String,
        sessionID: UUID,
        deviceName: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.tag = tag
        self.level = level
        self.message = message
        self.sessionID = sessionID
        self.deviceName = deviceName
    }
}

public enum LogEntryLevel: String, Codable, CaseIterable, Sendable {
    case debug
    case warning
    case error
    case unknown
}

extension LogEntry {
    public var logLevel: LogEntryLevel {
        LogEntryLevel(rawValue: level) ?? .unknown
    }
}

extension LogEntry {
    public static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
