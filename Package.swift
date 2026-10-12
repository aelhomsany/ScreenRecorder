// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScreenRecorder",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "ScreenRecorder",
            path: "Sources/ScreenRecorder",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
