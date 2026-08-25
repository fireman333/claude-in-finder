// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeInFinder",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "CCFKit", path: "Sources/CCFKit"),
        .executableTarget(name: "ccfinder", dependencies: ["CCFKit"], path: "Sources/ccfinder"),
        .executableTarget(name: "ccfinder-open", dependencies: ["CCFKit"], path: "Sources/ccfinder-open"),
    ]
)
