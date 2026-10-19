// swift-tools-version: 5.9
// 5.9 rather than 6.0 so older Command Line Tools can read this file too; it also builds in the
// Swift 5 language mode by default.
import PackageDescription

let package = Package(
    name: "ScreenRecorder",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(
            name: "ScreenRecorder",
            path: "Sources/ScreenRecorder"
        )
    ]
)
