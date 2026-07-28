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
        .executable(name: "apple-messages", targets: ["apple-messages"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.1"),
    ],
    targets: [
        .target(name: "AppleToolsVersion"),
        .target(name: "TCCResponsibility"),
        // Query parsing shared by mail and messages, so the two cannot drift on
        // what `budget review` means.
        .target(name: "AppleToolsSearch"),
        .target(
            name: "AppleToolsStyle",
            dependencies: [.product(name: "ArgumentParser", package: "swift-argument-parser")]
        ),
        .executableTarget(
            name: "reminders",
            dependencies: ["RemindersLibrary"],
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/reminders/Info.plist",
                ]),
            ]
        ),
        .target(
            name: "RemindersLibrary",
            dependencies: [
                "AppleToolsVersion",
                "AppleToolsStyle",
                "TCCResponsibility",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(
            name: "MailLibrary",
            dependencies: ["AppleToolsSearch"],
            linkerSettings: [
                // Mail's Envelope Index is a SQLite database; reading it directly
                // is what lets search skip AppleScript entirely.
                .linkedLibrary("sqlite3"),
            ]
        ),
        .executableTarget(
            name: "apple-mail",
            dependencies: [
                "AppleToolsVersion",
                "AppleToolsStyle",
                "MailLibrary",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/AppleMail"
        ),
        .executableTarget(
            name: "apple-calendar",
            dependencies: [
                "AppleToolsVersion",
                "AppleToolsStyle",
                "TCCResponsibility",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/AppleCalendar",
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/AppleCalendar/Info.plist",
                ]),
            ]
        ),
        .executableTarget(
            name: "apple-contacts",
            dependencies: [
                "AppleToolsVersion",
                "AppleToolsStyle",
                "TCCResponsibility",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/AppleContacts",
            exclude: ["Info.plist"],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                // Deprecated, but the only API that can remove a member from a
                // CardDAV-backed (iCloud) group; CNSaveRequest.removeMember
                // silently does nothing there. Used only as a fallback.
                .linkedFramework("AddressBook"),
                // macOS will not show the Contacts permission dialog unless the
                // binary carries NSContactsUsageDescription. A command-line tool
                // has no bundle, so the plist is embedded directly into the
                // __TEXT,__info_plist section.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/AppleContacts/Info.plist",
                ]),
            ]
        ),
        .testTarget(
            name: "RemindersTests",
            dependencies: ["RemindersLibrary"]
        ),
        .target(
            name: "MessagesLibrary",
            dependencies: ["AppleToolsSearch"],
            linkerSettings: [
                // chat.db is read directly, the same way MailLibrary reads the
                // Envelope Index. Messages exposes no AppleScript read path to
                // fall back to, so this is the only route to history.
                .linkedLibrary("sqlite3"),
            ]
        ),
        .executableTarget(
            name: "apple-messages",
            dependencies: [
                "AppleToolsVersion",
                "AppleToolsStyle",
                "MessagesLibrary",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/AppleMessages"
        ),
        .testTarget(
            name: "MailTests",
            dependencies: ["MailLibrary", "AppleToolsSearch"]
        ),
        .testTarget(
            name: "MessagesTests",
            dependencies: ["MessagesLibrary"]
        ),
    ]
)
