// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AarikKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "AarikCore", targets: ["AarikCore"]),
        .library(name: "MediaEngine", targets: ["MediaEngine"]),
        .executable(name: "aarik-dev", targets: ["aarik-dev"]),
    ],
    targets: [
        .target(
            name: "AarikCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MediaEngine",
            dependencies: ["AarikCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MediaTestSupport",
            dependencies: ["MediaEngine"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "aarik-dev",
            dependencies: ["MediaEngine", "MediaTestSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AarikCoreTests",
            dependencies: ["AarikCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MediaEngineTests",
            dependencies: ["MediaEngine", "MediaTestSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
