// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Intercept",
    platforms: [
        .macOS(.v26)
    ],
    dependencies: [
        // Shared "Graphite & Ember" theme, components and build scripts.
        // Must be checked out next to this folder.
        .package(path: "../GraphiteEmber")
    ],
    targets: [
        .executableTarget(
            name: "Intercept",
            dependencies: [
                .product(name: "GraphiteEmber", package: "GraphiteEmber")
            ],
            path: "Sources/Intercept",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
