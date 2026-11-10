// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Intercept",
    platforms: [
        .macOS(.v26)
    ],
    targets: [
        .executableTarget(
            name: "Intercept",
            path: "Sources/Intercept",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
