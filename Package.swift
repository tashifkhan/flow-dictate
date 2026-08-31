// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Flow",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Flow",
            path: "Sources/Flow",
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
