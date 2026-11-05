// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Luftbro",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Luftbro",
            path: "Sources/Luftbro"
        )
    ]
)
