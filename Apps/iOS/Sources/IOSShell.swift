import AppCore
import AppServices
import Convert
import ConvertUI
import Foundation
import Observation
import PhotosLibrary
import SwiftUI
import UIKit

/// The iOS composition root: builds `AppServices`, `ConvertModel` and `ConvertIOSScene`, filters tools by `.iOS`,
/// and wires the iOS platform host actions.
@MainActor
@Observable
final class IOSShell {
    let services: AppServices
    let convert: ConvertModel
    let scene: ConvertIOSScene
    let tools: [any Tool]

    init(
        directory: URL = IOSShell.supportDirectory(),
        defaults: UserDefaults = .standard,
        photoStore: any PhotoStore = PhotoKitStore()
    ) {
        let services = AppServices(directory: directory, defaults: defaults, photoStore: photoStore)
        let convert = ConvertModel(services: services)
        self.services = services
        self.convert = convert
        self.scene = ConvertIOSScene(model: convert)
        self.tools = ToolRegistry.tools(for: .iOS, from: [convert.tool])

        var host = ConvertHost()
        host.open = { urls in
            for url in urls {
                UIApplication.shared.open(url)
            }
        }
        host.reveal = { urls in
            IOSFileRevealer().reveal(urls)
        }
        host.showInPhotos = { _ in
            if let url = URL(string: "photos-redirect://") {
                UIApplication.shared.open(url)
            }
        }
        host.openPhotosAccessSettings = {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        }
        convert.host = host
    }

    func start() async {
        await convert.start()
    }

    func handleScenePhase(_ phase: ScenePhase) {
        if phase == .active {
            // Re-check Apple Intelligence availability and Photos access when returning to the foreground.
            convert.assistant.availability.refresh()
            Task { await convert.photos.start() }
        }
    }

    nonisolated static func supportDirectory() -> URL {
        #if DEBUG
            if let folder = LaunchArguments.value(of: "-uiTesting", in: ProcessInfo.processInfo.arguments) {
                return URL(filePath: folder, directoryHint: .isDirectory)
            }
        #endif
        return AppServices.supportDirectory(bundleIdentifier: Bundle.main.bundleIdentifier)
    }
}
