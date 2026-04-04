// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "openclaw-guardian",
    platforms: [.macOS("13.0")],
    products: [
        .executable(
            name: "openclaw-guardian",
            targets: ["App"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/stephencelis/SQLite.swift", from: "0.15.0")
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                .product(name: "SQLite", package: "SQLite.swift")
            ],
            path: "Sources"
        )
    ]
)
