// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ToskVoice",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "ToskVoice", targets: ["ToskVoice"]),
        .executable(name: "toskvoice-agent", targets: ["ToskVoiceAgent"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "ToskVoice",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "SpeakerKit", package: "argmax-oss-swift"),
                .product(name: "TTSKit", package: "argmax-oss-swift"),
            ],
            path: "Sources/ToskVoice",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "ToskVoiceTests",
            dependencies: ["ToskVoice"],
            path: "Tests/ToskVoiceTests"
        ),
        .executableTarget(
            name: "ToskVoiceAgent",
            path: "Sources/ToskVoiceAgent",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
    ]
)
