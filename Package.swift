// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Crocus",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        // Reads and writes ID3 tags in mp3 files (title/artist/album/year), so the
        // metadata editor can fix wrong tags at the source. Pure Swift, no external
        // binary — fetched once on first build.
        .package(url: "https://github.com/chicio/ID3TagEditor", from: "5.5.0")
    ],
    targets: [
        .executableTarget(
            name: "Crocus",
            dependencies: [
                .product(name: "ID3TagEditor", package: "ID3TagEditor")
            ],
            path: "Sources/Crocus",
            swiftSettings: [
                // Use the Swift 5 language mode to avoid strict-concurrency friction
                // with AVFoundation completion handlers during early development.
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
