// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AppModules",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "AppCore", targets: ["AppCore"]),
        .library(name: "MediaEngine", targets: ["MediaEngine"]),
        .library(name: "AppUI", targets: ["AppUI"]),
        .library(name: "LocalLibrary", targets: ["LocalLibrary"]),
        .library(name: "DownscaleVideo", targets: ["DownscaleVideo"]),
        .executable(name: "devtool", targets: ["devtool"]),
    ],
    targets: [
        .target(
            name: "AppCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MediaEngine",
            dependencies: ["AppCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "AppUI",
            dependencies: ["AppCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "LocalLibrary",
            dependencies: ["MediaEngine", "AppCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "DownscaleVideo",
            dependencies: ["AppUI", "MediaEngine", "AppCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MediaTestSupport",
            dependencies: ["MediaEngine"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "devtool",
            dependencies: ["MediaEngine", "MediaTestSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AppCoreTests",
            dependencies: ["AppCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MediaEngineTests",
            dependencies: ["MediaEngine", "MediaTestSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AppUITests",
            dependencies: ["AppUI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LocalLibraryTests",
            dependencies: ["LocalLibrary", "MediaTestSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DownscaleVideoTests",
            dependencies: ["DownscaleVideo"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
