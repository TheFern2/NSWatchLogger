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
        .target(
            name: "NSWatchLoggerDirect",
            dependencies: ["NSWatchLogger", "NSWatchLoggerModels"]
        ),
        .target(
            name: "NSWatchLoggerServer",
            dependencies: ["NSWatchLoggerModels"]
        ),
        .executableTarget(
            name: "LogServerCLI",
            dependencies: ["NSWatchLoggerModels", "NSWatchLoggerServer"]
        ),
    ]
)
