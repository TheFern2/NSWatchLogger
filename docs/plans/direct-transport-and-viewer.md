# Direct Transport and macOS Log Viewer

## Context

Currently NSWatchLogger routes all logs through the paired iPhone via WatchConnectivity. This requires the companion app to be running and adds latency. We want the watch to send logs directly to a macOS viewer over the local network (Wi-Fi or cellular), and we want to own the viewer end-to-end rather than depending on NSLogger.

This plan adds three new SPM modules to the existing package and a macOS SwiftUI viewer app, all in the same repo.

## Architecture

```
                  watchOS                           macOS
         +-----------------------+         +---------------------+
         |  WatchLogger.log()    |         |   WatchLogViewer    |
         |         |             |         |       (SwiftUI)     |
         |  DirectLogTransport   |  Wi-Fi  |     LogServer       |
         |    HTTP | WebSocket   | ------> |  HTTP | WebSocket   |
         |         |             |         |  Bonjour advertise  |
         |  Bonjour discover     |         +---------------------+
         +-----------------------+
```

### New targets

| Target | Purpose | Dependencies |
|---|---|---|
| `NSWatchLoggerModels` | Shared Codable `LogEntry`, Bonjour constants | none |
| `NSWatchLoggerDirect` | HTTP + WebSocket transport for watchOS | `NSWatchLogger`, `NSWatchLoggerModels` |
| `NSWatchLoggerServer` | HTTP + WebSocket listener, Bonjour advertisement | `NSWatchLoggerModels` |

The macOS app (`WatchLogViewer/`) consumes `NSWatchLoggerModels` and `NSWatchLoggerServer` as local package dependencies.

### Package.swift final state

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NSWatchLogger",
    platforms: [.watchOS(.v10), .iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "NSWatchLogger", targets: ["NSWatchLogger"]),
        .library(name: "NSWatchLoggerRelay", targets: ["NSWatchLoggerRelay"]),
        .library(name: "NSWatchLoggerModels", targets: ["NSWatchLoggerModels"]),
        .library(name: "NSWatchLoggerDirect", targets: ["NSWatchLoggerDirect"]),
        .library(name: "NSWatchLoggerServer", targets: ["NSWatchLoggerServer"]),
    ],
    targets: [
        .target(name: "NSWatchLogger"),
        .target(name: "NSWatchLoggerRelay"),
        .target(name: "NSWatchLoggerModels"),
        .target(name: "NSWatchLoggerDirect",
                dependencies: ["NSWatchLogger", "NSWatchLoggerModels"]),
        .target(name: "NSWatchLoggerServer",
                dependencies: ["NSWatchLoggerModels"]),
    ]
)
```

### Directory structure after all phases

```
Sources/
  NSWatchLogger/              (existing, untouched)
  NSWatchLoggerRelay/         (existing, untouched)
  NSWatchLoggerModels/        (Phase 1)
    LogEntry.swift
    BonjourConstants.swift
  NSWatchLoggerDirect/        (Phase 2)
    DirectLogTransport.swift
    ConnectionStatus.swift
    BonjourDiscovery.swift
    HTTPLogSender.swift
    WebSocketLogSender.swift
    LogQueue.swift
  NSWatchLoggerServer/        (Phase 3)
    LogServer.swift
    HTTPListener.swift
    WebSocketListener.swift
    ClientConnection.swift
    BonjourAdvertiser.swift
WatchLogViewer/               (Phase 4)
  WatchLogViewer.xcodeproj
  WatchLogViewer/
    WatchLogViewerApp.swift
    Models/
      LogStore.swift
      ViewerSettings.swift
    Views/
      ContentView.swift
      Sidebar/
        SessionListView.swift
        ConnectionStatusView.swift
      LogTable/
        LogTableView.swift
        LogDetailView.swift
      Toolbar/
        FilterBar.swift
        ExportView.swift
    Utilities/
      LogFormatter.swift
      TagColors.swift
```

## Phase 1: Shared Models (`NSWatchLoggerModels`)

Defines the wire format both sides agree on. No platform restrictions.

### `LogEntry.swift`

```swift
public struct LogEntry: Codable, Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let tag: String
    public let level: String
    public let message: String
    public let sessionID: UUID
    public let deviceName: String?
}
```

- JSON-encoded with `.iso8601` date strategy for HTTP bodies and WebSocket text frames
- `sessionID` groups entries by transport connection lifetime
- `deviceName` populated from `WKInterfaceDevice.current().name` on watchOS

### `BonjourConstants.swift`

```swift
public enum BonjourConstants {
    public static let serviceType = "_watchlog._tcp"
    public static let httpPathLog = "/log"
    public static let httpPathBatch = "/logs"
    public static let wsPath = "/ws"
    public static let defaultPort: UInt16 = 9830
}
```

### Package.swift changes

- Add `.macOS(.v14)` to platforms
- Add `NSWatchLoggerModels` target and product

## Phase 2: Direct Transport (`NSWatchLoggerDirect`)

A `WatchLogTransport` implementation that sends logs over the network. Drop-in replacement -- consumers call `WatchLogger.configure(transport: directTransport, enabled: true)`.

### `DirectLogTransport.swift`

- Conforms to `WatchLogTransport` (the existing protocol: `sendLog(payload: [String: Any])`)
- Bridges `[String: Any]` payload into a `LogEntry` (extracts tag/level/message, adds id/timestamp/sessionID)
- `TransportMode` enum: `.http`, `.webSocket`
- Configure with explicit host or nil for Bonjour discovery
- `sessionID` generated once at init, constant for instance lifetime
- `connectionStatus: ConnectionStatus` property for observability
- Thread safety via `NSLock` (consistent with existing codebase)

### `ConnectionStatus.swift`

```swift
public enum ConnectionStatus: Sendable {
    case disconnected, discovering, connecting, connected, reconnecting
}
```

### `BonjourDiscovery.swift`

- `NWBrowser` for `BonjourConstants.serviceType`
- Callback: `onServiceFound: (NWEndpoint) -> Void`
- Handles start/stop/state changes
- Picks first discovered service (could be extended for selection)

### `HTTPLogSender.swift`

- `URLSession` POST to `http://<host>:<port>/log`
- JSON body is the encoded `LogEntry`
- Batch mode: accumulates entries then POSTs to `/logs`
- Retry with backoff (1s, 2s, 4s -- max 3 retries)

### `WebSocketLogSender.swift`

- `NWConnection` with `NWProtocolWebSocket.Options`
- Sends each `LogEntry` as a JSON text frame
- Reconnection with backoff (1s, 2s, 4s, 8s -- max 30s)
- Ping/pong heartbeat every 15s

### `LogQueue.swift`

- Ring buffer, default capacity 500 entries
- Shared by both senders: enqueue when disconnected, flush on reconnect
- Thread-safe via `NSLock`

### Constraints

- watchOS needs Wi-Fi or cellular for direct networking -- must be documented
- Bonjour discovery may be slow on watch due to power-saving network behavior
- `deviceName` uses `#if os(watchOS)` conditional import of WatchKit

## Phase 3: Server Networking (`NSWatchLoggerServer`)

Reusable server-side networking. macOS only in practice, but no artificial platform restriction.

### `LogServer.swift`

- `ObservableObject` with `@Published isRunning` and `@Published connections`
- Owns `HTTPListener`, `WebSocketListener`, `BonjourAdvertiser`
- `onLogReceived: ((LogEntry) -> Void)?` callback
- `start(port:)` / `stop()`

### `HTTPListener.swift`

- `NWListener` on configured port
- Parses minimal HTTP: only handles `POST /log` and `POST /logs` with `Content-Length`
- Decodes JSON body into `LogEntry` / `[LogEntry]`
- Returns `200 OK` or `400 Bad Request`

### `WebSocketListener.swift`

- `NWListener` with `NWProtocolWebSocket.Options`
- Accepts connections, receives text frames, decodes `LogEntry`
- Tracks each connection as a `ClientConnection`
- Responds to pings

### Approach to HTTP + WebSocket on a single port

Use two `NWListener` instances on separate ports: the configured port for HTTP, port+1 for WebSocket. Both advertised via Bonjour with TXT record metadata indicating protocol. If this proves awkward, collapse to a single listener that detects upgrade headers -- but two ports is simpler to implement and debug.

### `BonjourAdvertiser.swift`

- Uses `NWListener.service` property to advertise
- Service type: `BonjourConstants.serviceType`
- Separate advertisements for HTTP and WebSocket listeners (with TXT records distinguishing them)

### `ClientConnection.swift`

```swift
public struct ClientConnection: Identifiable, Sendable {
    public let id: UUID
    public let remoteEndpoint: String
    public let connectedAt: Date
    public let sessionID: UUID?
    public let transportType: TransportType
}

public enum TransportType: String, Sendable {
    case http, webSocket
}
```

## Phase 4: macOS Viewer App (`WatchLogViewer`)

SwiftUI macOS app. Xcode project in `WatchLogViewer/` that depends on the local SPM package for `NSWatchLoggerModels` and `NSWatchLoggerServer`.

### App entry point

- `@StateObject` for `LogServer` and `LogStore`
- Starts server on launch
- Wires `server.onLogReceived` to `store.append(_:)`

### `LogStore`

- `@Observable`, holds all received `LogEntry` values
- Groups by `sessionID` for sidebar
- Filtering: search text, level set, tag set, session selection
- Max 50,000 entries (configurable), drops oldest when exceeded
- Debounced search (250ms) to avoid filtering on every keystroke

### Layout: `NavigationSplitView`

**Sidebar**
- Session list: device name, start time, entry count per session
- "All Sessions" entry at top
- Connection status: Bonjour state (green/red dot), active connection count, client list with transport type

**Detail area**
- `Table` with columns: timestamp (HH:mm:ss.SSS), tag (color-coded), level (icon + color), message (truncated)
- Sortable columns
- Single selection drives detail pane
- Auto-scroll to bottom on new entries; pauses when user scrolls up

**Detail pane**
- Full `LogEntry` fields
- Monospaced, selectable, scrollable message text
- Copy button

**Toolbar**
- Search field
- Level toggle buttons (debug/warning/error)
- Tag multi-select popup
- Clear button
- Export button (JSON or plain text via `NSSavePanel`)
- Auto-scroll toggle
- Connection status indicator

### `TagColors`

- Fixed colors for built-in tags: network=blue, workout=green, service=orange, debug=gray
- Custom tags hashed to a consistent color from a palette

### `LogFormatter`

- Plain text export format: `[HH:mm:ss.SSS] [TAG] [LEVEL] message`

### Entitlements

- `com.apple.security.network.server` (listen for connections)
- `com.apple.security.network.client` (Bonjour)
- App Sandbox enabled

## Phase 5: Integration and Documentation

1. End-to-end test: watchOS app with `DirectLogTransport` -> WatchLogViewer
2. README updates: direct transport section, viewer section, architecture diagram, Wi-Fi constraint documentation
3. Error handling audit: Network.framework error states, graceful degradation on Wi-Fi loss, malformed JSON handling
4. Performance: verify Table handles large log counts, debounced search, batch HTTP sends

## Phase sequencing

```
Phase 1 (Models)  -->  Phase 2 (Direct Transport)  --\
                  \                                    --> Phase 5 (Integration)
                   -->  Phase 3 (Server) --> Phase 4 (Viewer) --/
```

Phase 1 first (everything depends on it). Phases 2 and 3 can run in parallel. Phase 4 needs Phase 3. Phase 5 ties it together.

## Known challenges

**Network.framework HTTP parsing:** `NWListener` does not provide a high-level HTTP server. The HTTP listener must parse request lines and headers from raw TCP data. We constrain to only `POST /log` and `POST /logs` with `Content-Length`, keeping parsing minimal.

**Two ports vs. one:** Serving HTTP and WebSocket on a single port requires detecting protocol from initial bytes. Simpler to use two ports with separate Bonjour advertisements.

**watchOS networking availability:** The watch has Wi-Fi when connected to a known network and when the paired iPhone is not nearby (or on cellular models). The transport must report connection status. This is a fundamental constraint, not a bug.

**Bonjour on watchOS:** `NWBrowser` works on watchOS 6+ but discovery may be slow due to power-saving network behavior on watch.

## Verification

1. Build the package: `swift build` should compile all five targets with no errors
2. Create a minimal watchOS test app that configures `DirectLogTransport` with a hardcoded host
3. Launch WatchLogViewer on Mac, verify Bonjour advertisement appears
4. Send logs from watch, verify they appear in the viewer table
5. Test WebSocket reconnection: stop/start the viewer, verify watch reconnects and queued logs flush
6. Test filtering: verify search, level filter, tag filter, session filter all work
7. Test export: export filtered logs as JSON and plain text, verify file contents
