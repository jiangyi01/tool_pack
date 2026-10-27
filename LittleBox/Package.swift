// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "LittleBox",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "LittleBox",
            path: "Sources/LittleBox"
        )
    ]
)
