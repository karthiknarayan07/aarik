// swift-tools-version: 6.2
import PackageDescription

// The Convert tool: planning, presets, estimates, the runners (verify, Replace, Trash), the assistant features that
// read its results, and its SwiftUI views. Depends on Core; no app and no other tool depends on it except the app
// shells. QuickRunService (Shortcuts, Services, the menu bar and Dock entry points) is built here because it speaks
// Convert's jobs, but only the Mac app links it.
let package = Package(
    name: "Convert",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "Convert", targets: ["Convert"]),
        .library(name: "ConvertUI", targets: ["ConvertUI"]),
        .library(name: "QuickRunService", targets: ["QuickRunService"]),
    ],
    dependencies: [
        .package(path: "../../Core")
    ],
    targets: [
        .target(
            name: "Convert",
            dependencies: [
                .product(name: "AppCore", package: "Core"),
                .product(name: "MediaEngine", package: "Core"),
                .product(name: "LocalLibrary", package: "Core"),
                .product(name: "PhotosLibrary", package: "Core"),
                .product(name: "Assistant", package: "Core"),
                .product(name: "AppUI", package: "Core"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "ConvertUI",
            dependencies: [
                "Convert",
                .product(name: "AppCore", package: "Core"),
                .product(name: "MediaEngine", package: "Core"),
                .product(name: "AppUI", package: "Core"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "QuickRunService",
            dependencies: [
                "Convert",
                .product(name: "AppCore", package: "Core"),
                .product(name: "MediaEngine", package: "Core"),
                .product(name: "LocalLibrary", package: "Core"),
                .product(name: "PhotosLibrary", package: "Core"),
                .product(name: "AppUI", package: "Core"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ConvertTests",
            dependencies: [
                "Convert", "ConvertUI",
                .product(name: "AppCore", package: "Core"),
                .product(name: "MediaEngine", package: "Core"),
                .product(name: "LocalLibrary", package: "Core"),
                .product(name: "PhotosLibrary", package: "Core"),
                .product(name: "Assistant", package: "Core"),
                .product(name: "AppUI", package: "Core"),
                .product(name: "MediaTestSupport", package: "Core"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "QuickRunServiceTests",
            dependencies: [
                "QuickRunService", "Convert",
                .product(name: "AppCore", package: "Core"),
                .product(name: "MediaEngine", package: "Core"),
                .product(name: "LocalLibrary", package: "Core"),
                .product(name: "PhotosLibrary", package: "Core"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
