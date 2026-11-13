// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SlyySnap",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "SlyySnap", path: "Sources/SlyySnap"),
    ]
)
