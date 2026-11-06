// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Cumulus",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Cumulus", path: "Sources/Cumulus")
    ]
)
