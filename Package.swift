// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NSWatchLogger",
    platforms: [.watchOS(.v10), .iOS(.v17)],
    products: [
        .library(name: "NSWatchLogger", targets: ["NSWatchLogger"]),
        .library(name: "NSWatchLoggerRelay", targets: ["NSWatchLoggerRelay"]),
    ],
    targets: [
        .target(name: "NSWatchLogger"),
        .target(name: "NSWatchLoggerRelay"),
    ]
)
