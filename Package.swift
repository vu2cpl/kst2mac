// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KSTMac",
    platforms: [.macOS(.v13)],
    products: [
        // The app itself.
        .executable(name: "KSTMac", targets: ["KSTMacApp"]),
        // Headless transcript recorder — connects, logs in, dumps every
        // byte the server sends to a file so the line parser can be
        // written against real traffic instead of guesses. See
        // docs/PROTOCOL.md.
        .executable(name: "KSTCapture", targets: ["KSTCapture"]),
    ],
    targets: [
        // Protocol layer: telnet codec, login state machine, line parser,
        // Maidenhead maths. No AppKit/SwiftUI — unit-testable on its own.
        .target(name: "KSTCore", path: "Sources/KSTCore"),
        .executableTarget(
            name: "KSTMacApp",
            dependencies: ["KSTCore"],
            path: "Sources/KSTMacApp",
            exclude: ["Info.plist"]
        ),
        .executableTarget(
            name: "KSTCapture",
            dependencies: ["KSTCore"],
            path: "tools/KSTCapture"
        ),
        .testTarget(
            name: "KSTCoreTests",
            dependencies: ["KSTCore"],
            path: "Tests/KSTCoreTests"
        ),
    ]
)
