// swift-tools-version: 6.2
import PackageDescription

// Everything that is not specific to one tool: the queue and jobs, settings, pressure policy, the tool and scene
// protocols, the shared services every tool works with, the engine, the libraries and the shared views. Tools depend on this
// package; this package never depends on a tool.
let package = Package(
    name: "Core",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "AppCore", targets: ["AppCore"]),
        .library(name: "MediaEngine", targets: ["MediaEngine"]),
        .library(name: "LocalLibrary", targets: ["LocalLibrary"]),
        .library(name: "PhotosLibrary", targets: ["PhotosLibrary"]),
        .library(name: "Assistant", targets: ["Assistant"]),
        .library(name: "AppUI", targets: ["AppUI"]),
        .library(name: "AppServices", targets: ["AppServices"]),
        .library(name: "MediaTestSupport", targets: ["MediaTestSupport"]),
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
            name: "PhotosLibrary",
            dependencies: ["MediaEngine", "AppCore", "LocalLibrary"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "Assistant",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "AppServices",
            dependencies: ["AppCore", "MediaEngine", "LocalLibrary", "PhotosLibrary", "Assistant"],
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
            name: "AppServicesTests",
            dependencies: ["AppServices", "AppCore", "PhotosLibrary", "Assistant"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LocalLibraryTests",
            dependencies: ["LocalLibrary", "MediaTestSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PhotosLibraryTests",
            dependencies: ["PhotosLibrary", "LocalLibrary", "AppCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // XCTest, not Swift Testing: `measure(metrics:)` and the clock and memory metrics are XCTest's.
        // Off unless RUN_PERF_TESTS=1 (see PERFORMANCE.md).
        .testTarget(
            name: "PerformanceTests",
            dependencies: ["MediaEngine", "MediaTestSupport"],
            exclude: ["Baselines"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
