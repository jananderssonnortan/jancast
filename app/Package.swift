// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Jancast",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Jancast",
            path: "Sources/Jancast"
        )
    ]
)
