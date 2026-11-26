import AppCore
import AppServices
import Foundation
import PhotosLibrary
import Testing

@testable import Convert
@testable import ConvertUI

private func makeDirectory() throws -> URL {
    let directory = URL.temporaryDirectory.appending(
        path: "convert-model-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@MainActor
private func makeModel(directory: URL, defaults: UserDefaults? = nil) -> ConvertModel {
    let suite = defaults ?? UserDefaults(suiteName: "ConvertModelAndSceneTests-\(UUID().uuidString)")!
    let services = AppServices(directory: directory, defaults: suite, photoStore: FakePhotoStore())
    return ConvertModel(services: services)
}

@MainActor
@Suite struct ConvertModelAndSceneTests {
    @Test func modelRegistersConvertRunnersOnSharedQueue() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(directory: directory)
        #expect(model.services.queue.registeredToolIDs == [ConvertTool.toolID, ConvertTool.photosToolID])
    }

    @Test func presetAndInspectorStatePersistToServicesDefaults() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "ConvertModelAndSceneTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let model = makeModel(directory: directory, defaults: defaults)
        model.preset = .smaller
        model.isInspectorPresented = false

        let reloaded = makeModel(directory: directory, defaults: UserDefaults(suiteName: suiteName)!)
        #expect(reloaded.preset == .smaller)
        #expect(!reloaded.isInspectorPresented)
    }

    @Test func showQueueUsesHostAndSelectsQueue() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(directory: directory)
        var showedWindow = false
        model.host.showMainWindow = { showedWindow = true }

        model.showQueue()
        #expect(showedWindow)
        #expect(model.selection == .queue)
    }

    @Test func addVideosCommandShowsWindowSwitchesToLocalFilesAndOpensImporter() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(directory: directory)
        var showedWindow = false
        model.host.showMainWindow = { showedWindow = true }
        model.selection = .queue

        model.perform(.addVideos)
        #expect(showedWindow)
        #expect(model.selection == .localFiles)
        #expect(model.isImporterPresented)
    }

    @Test func openPhotosAccessSettingsCallsHost() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(directory: directory)
        var openedSettings = false
        model.host.openPhotosAccessSettings = { openedSettings = true }

        model.openPhotosAccessSettings()
        #expect(openedSettings)
    }

    @Test func applyDefaultSaveLocationReadsServicesDefaults() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = UserDefaults(suiteName: "ConvertModelAndSceneTests-\(UUID().uuidString)")!
        let model = makeModel(directory: directory, defaults: defaults)
        model.saveLocation.choice = .folder
        defaults.set(SaveLocation.Choice.nextToOriginal.rawValue, forKey: AppSettings.Keys.defaultSaveTo)

        model.applyDefaultSaveLocation()
        #expect(model.saveLocation.choice == .nextToOriginal)
    }

    #if os(macOS)
        @Test func sceneExposesConvertToolAndMirrorsSelectionAndInspector() throws {
            let directory = try makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let model = makeModel(directory: directory)
            let scene = ConvertMacScene(model: model)

            #expect(scene.tool.id == ConvertTool.toolID)
            #expect(scene.tool.platforms == [.macOS, .iOS])

            scene.selection = .overview
            scene.isInspectorPresented = false
            #expect(model.selection == .overview)
            #expect(!model.isInspectorPresented)
        }

        @Test func sceneReportsInspectorAvailabilityByPage() throws {
            let directory = try makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let scene = ConvertMacScene(model: makeModel(directory: directory))

            #expect(scene.hasInspector(for: .localFiles))
            #expect(scene.hasInspector(for: .mediaType(.k4)))
            #expect(scene.hasInspector(for: .photosVideos))
            #expect(!scene.hasInspector(for: .overview))
            #expect(!scene.hasInspector(for: .queue))
            #expect(!scene.hasInspector(for: .completed))
            #expect(!scene.hasInspector(for: .keptAsIs))
            #expect(!scene.hasInspector(for: .failed))
            #expect(!scene.hasInspector(for: nil))
        }

        @Test func sceneReportsContextMenusAndFileDropsByPage() throws {
            let directory = try makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let scene = ConvertMacScene(model: makeModel(directory: directory))

            #expect(scene.hasContextMenu(for: .localFiles))
            #expect(scene.hasContextMenu(for: .queue))
            #expect(scene.hasContextMenu(for: .failed))
            #expect(!scene.hasContextMenu(for: .overview))
            #expect(!scene.hasContextMenu(for: .photosVideos))
            #expect(!scene.hasContextMenu(for: .completed))
            #expect(!scene.hasContextMenu(for: .keptAsIs))

            #expect(scene.acceptsFileDrop(on: .localFiles))
            #expect(!scene.acceptsFileDrop(on: .overview))
            #expect(!scene.acceptsFileDrop(on: .queue))
        }

        @Test func sceneDropFilesAddsToLibraryAndSelectsLocalFiles() throws {
            let directory = try makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let model = makeModel(directory: directory)
            let scene = ConvertMacScene(model: model)
            scene.selection = .overview

            #expect(!scene.dropFiles([], on: .localFiles))
            #expect(scene.dropFiles([URL(filePath: "/tmp/nonexistent.mov")], on: .localFiles))
            #expect(model.selection == .localFiles)
            model.library.cancelScan()
        }
    #elseif os(iOS)
        @Test func iosSceneExposesConvertToolAndMirrorsSelection() throws {
            let directory = try makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let model = makeModel(directory: directory)
            let scene = ConvertIOSScene(model: model)

            #expect(scene.tool.id == ConvertTool.toolID)
            #expect(scene.tool.platforms == [.macOS, .iOS])

            scene.selection = .overview
            #expect(model.selection == .overview)
        }
    #endif
}
