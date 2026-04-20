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
            exclude: ["App/Resources/AppIcon.icns"],
            resources: [
                // Monaco editor host page + runtime. `vs/` is fetched by
                // scripts/fetch-monaco.sh (or `make monaco`) and is not
                // checked in — only .gitkeep lives under monaco/ by default.
                .copy("App/Resources/editor"),
                .copy("App/Resources/monaco"),
            ]
        ),
        .testTarget(
            name: "KilnTests",
            dependencies: ["Kiln"],
            path: "Tests/KilnTests"
        ),
    ]
)
