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
        .executable(name: "apple-contacts", targets: ["apple-contacts"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.1"),
    ],
    targets: [
        .target(name: "AppleToolsVersion"),
        .target(
            name: "AppleToolsStyle",
            dependencies: [.product(name: "ArgumentParser", package: "swift-argument-parser")]
        ),
        .executableTarget(
            name: "reminders",
            dependencies: ["RemindersLibrary"]
        ),
        .target(
            name: "RemindersLibrary",
            dependencies: [
                "AppleToolsVersion",
                "AppleToolsStyle",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "apple-mail",
            dependencies: [
                "AppleToolsVersion",
                "AppleToolsStyle",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/AppleMail"
        ),
        .executableTarget(
            name: "apple-calendar",
            dependencies: [
                "AppleToolsVersion",
                "AppleToolsStyle",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/AppleCalendar"
        ),
        .executableTarget(
            name: "apple-contacts",
            dependencies: [
                "AppleToolsVersion",
                "AppleToolsStyle",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/AppleContacts",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "RemindersTests",
            dependencies: ["RemindersLibrary"]
        ),
    ]
)
