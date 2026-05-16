# NSWatchLogger

A lightweight log relay that routes watchOS log messages to an iPhone companion app over WatchConnectivity. Designed as the Watch-side counterpart to NSLogger.

No external dependencies. Pure Swift.

## Products

- **NSWatchLogger** — import on watchOS. Logger enum + transport protocol.
- **NSWatchLoggerRelay** — import on iOS. Payload receiver + sink protocol.

## Watch Side

```swift
import NSWatchLogger

// At app startup:
WatchLogger.configure(transport: wcManager, enabled: true)

// Anywhere:
WatchLogger.log(.network, .debug, "Reachability changed")
WatchLogger.log(.custom("rowing"), .warning, "Sensor dropped")
```

Your `WatchConnectivityManager` conforms to `WatchLogTransport`:

```swift
extension WatchConnectivityManager: WatchLogTransport {
    public func sendLog(payload: [String: Any]) {
        guard WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(payload, replyHandler: nil) { _ in }
    }
}
```

## iPhone Side

```swift
import NSWatchLoggerRelay

struct MyLogSink: WatchLogSink {
    func log(domain: String, level: String, message: String) {
        // Route to NSLogger, os_log, swift-log, print, etc.
    }
}

// At app startup:
WatchLogRelay.configure(sink: MyLogSink())

// In WCSession delegate when receiving messages:
if message["type"] as? String == "watchLog" {
    WatchLogRelay.process(message)
}
```

## Payload Format

```json
{
  "type": "watchLog",
  "tag": "network",
  "level": "debug",
  "message": "Reachability changed"
}
```

## Tags

Built-in: `.network`, `.workout`, `.service`, `.debug`
Custom: `.custom("yourTag")`

## Levels

`.debug`, `.warning`, `.error`

## Thread Safety

Both `WatchLogger` and `WatchLogRelay` use `NSLock` to guard mutable state. Safe to call from any thread.

## Design Decisions

- No WCSession dependency in the library — the transport protocol keeps it decoupled.
- No queuing or retry — fire-and-forget. If Watch is unreachable, the log prints locally but is not relayed.
- Two separate products — Watch apps don't need the relay; iPhone apps don't need the logger.
- String-based payload — `[String: Any]` dicts for maximum WCSession compatibility.
