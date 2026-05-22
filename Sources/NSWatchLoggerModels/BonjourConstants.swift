import Foundation

public enum BonjourConstants {
    public static let serviceType = "_watchlog._tcp"
    public static let httpPathLog = "/log"
    public static let httpPathBatch = "/logs"
    public static let wsPath = "/ws"
    public static let defaultPort: UInt16 = 9830
    public static let wsPortOffset: UInt16 = 1
}
