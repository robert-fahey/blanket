// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Blanket",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Blanket",
            path: "Sources/Blanket"
        )
    ]
)
