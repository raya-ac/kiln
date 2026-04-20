// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Kiln",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Kiln", targets: ["Kiln"]),
    ],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.1"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.5"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Kiln",
            dependencies: [
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources",
            // AppIcon.icns is only used by scripts/make-app-bundle.sh when
            // assembling Kiln.app — the Swift runtime never reads it, so
            // exclude it from SPM's resource handling.
            exclude: ["App/Resources/AppIcon.icns"]
        ),
        .testTarget(
            name: "KilnTests",
            dependencies: ["Kiln"],
            path: "Tests/KilnTests"
        ),
    ]
)
