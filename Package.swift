// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AppVolume",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(name: "AppVolume", path: "Sources/AppVolume")
    ]
)
