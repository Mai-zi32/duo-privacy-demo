// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "DuoPrivacyDemo",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "DuoPrivacyDemo", targets: ["DuoPrivacyDemo"])
    ],
    targets: [
        .executableTarget(
            name: "DuoPrivacyDemo",
            path: "Sources/DuoPrivacyDemo"
        )
    ]
)
