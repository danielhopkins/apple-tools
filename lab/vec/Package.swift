// swift-tools-version:5.9
import PackageDescription

// No external dependencies on purpose: the lab must build offline and fast.
// Argument parsing is done by hand in each main.swift.
let package = Package(
    name: "vec",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "vec", path: "Sources/vec"),
        // 🛑 A SECOND BINARY IN THE SAME PACKAGE, not a second package. One
        // `swift build` produces both, so `make build`, `app/stage.sh` and
        // `make dist` each gained one copy line rather than a whole build.
        .executableTarget(name: "doctext", path: "Sources/doctext"),
    ]
)
