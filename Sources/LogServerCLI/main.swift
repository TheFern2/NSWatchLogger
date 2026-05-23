import Foundation
import NSWatchLoggerModels
import NSWatchLoggerServer

let server = LogServer()

server.onLogReceived = { entry in
    let ts = ISO8601DateFormatter().string(from: entry.timestamp)
    print("[\(ts)] [\(entry.tag)] [\(entry.level)] \(entry.message)")
}

let port: UInt16 = 9830
server.start(port: port)

print("LogServer running")
print("  HTTP:       http://localhost:\(port)\(BonjourConstants.httpPathLog)")
print("  HTTP batch: http://localhost:\(port)\(BonjourConstants.httpPathBatch)")
print("  Bonjour:    advertising as \(BonjourConstants.serviceType)")
print("")
print("Press Ctrl+C to stop")

RunLoop.current.run()
