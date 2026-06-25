// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ACertainSound",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "ACertainSound",
            path: "Sources/ACertainSound",
            swiftSettings: [
                // Use the Swift 5 language mode to avoid strict-concurrency friction
                // with AVFoundation completion handlers during early development.
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
