// swift-tools-version:5.9
import PackageDescription

// No external dependencies on purpose: the lab must build offline and fast.
// Argument parsing is done by hand in main.swift.
let package = Package(
    name: "vec",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "vec", path: "Sources/vec")
    ]
)
