// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "apple-tools",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "reminders", targets: ["reminders"]),
        .executable(name: "apple-mail", targets: ["apple-mail"]),
        .executable(name: "apple-calendar", targets: ["apple-calendar"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.1"),
    ],
    targets: [
        .executableTarget(
            name: "reminders",
            dependencies: ["RemindersLibrary"]
        ),
        .target(
            name: "RemindersLibrary",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "apple-mail",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/AppleMail"
        ),
        .executableTarget(
            name: "apple-calendar",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/AppleCalendar"
        ),
        .testTarget(
            name: "RemindersTests",
            dependencies: ["RemindersLibrary"]
        ),
    ]
)
