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
        #expect(
            model.services.queue.registeredToolIDs == [
                ConvertTool.toolID, ConvertTool.photosToolID, ConvertTool.imageToolID, ConvertTool.imagePhotosToolID,
            ])
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

    @Test func theSelectedPageIsRestoredOnTheNextLaunch() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "ConvertModelAndSceneTests-\(UUID().uuidString)"
        let model = makeModel(directory: directory, defaults: UserDefaults(suiteName: suiteName)!)
        #expect(model.selection == .localFiles)
        model.selection = .queue
        // A filter is not a page to come back to: the last stored page stays.
        model.selection = .mediaType(.k4)

        let reloaded = makeModel(directory: directory, defaults: UserDefaults(suiteName: suiteName)!)
        #expect(reloaded.selection == .queue)
        reloaded.selection = .overview
        let again = makeModel(directory: directory, defaults: UserDefaults(suiteName: suiteName)!)
        #expect(again.selection == .overview)
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
        let expected = SaveLocation.defaultChoice()
        defaults.set(expected.rawValue, forKey: AppSettings.Keys.defaultSaveTo)

        model.applyDefaultSaveLocation()
        #expect(model.saveLocation.choice == expected)
    }

    #if os(macOS)
        @Test func sceneExposesConvertToolAndMirrorsSelectionAndInspector() throws {
            let directory = try makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let model = makeModel(directory: directory)
            let scene = ConvertMacScene(model: model)

            #expect(scene.tool.id == ConvertTool.toolID)
            #expect(scene.tool.platforms == [.macOS, .iOS])

            scene.selection = .home
            scene.isInspectorPresented = false
            #expect(model.selection == .overview)
            #expect(scene.selection == .home)
            // Home, Ask and the tool's pages round-trip through the shell's page type.
            for page in [MacShellPage<VideoPage>.ask, .page(.queue), .page(.mediaType(.k4)), .home] {
                scene.selection = page
                #expect(scene.selection == page)
            }
            #expect(model.selection == .overview)
            #expect(!model.isInspectorPresented)
        }

        @Test func everyPageHasTheInspectorColumnSoTheLayoutStaysPut() throws {
            let directory = try makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let scene = ConvertMacScene(model: makeModel(directory: directory))

            #expect(scene.hasInspector(for: .localFiles))
            #expect(scene.hasInspector(for: .mediaType(.k4)))
            #expect(scene.hasInspector(for: .photosVideos))
            #expect(!scene.hasInspector(on: .home))
            #expect(scene.hasInspector(on: .ask))
            #expect(scene.hasInspector(for: .queue))
            #expect(scene.hasInspector(for: .completed))
            #expect(scene.hasInspector(for: .keptAsIs))
            #expect(scene.hasInspector(for: .failed))
            #expect(scene.hasInspector(for: nil))
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
            scene.selection = .home

            #expect(!scene.dropFiles([], on: .localFiles))
            #expect(scene.dropFiles([URL(filePath: "/tmp/nonexistent.mov")], on: .localFiles))
            #expect(model.selection == .localFiles)
            model.library.cancelScan()
        }
    #elseif os(iOS)
        @Test func iosSceneExposesConvertToolAndStartsOnTheHome() throws {
            let directory = try makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let model = makeModel(directory: directory)
            model.selection = .localFiles
            let scene = ConvertIOSScene(model: model)

            #expect(scene.tool.id == ConvertTool.toolID)
            #expect(scene.tool.platforms == [.macOS, .iOS])
            // The model starts on the Mac's first page; the iOS scene moves it to the home.
            #expect(model.selection == .overview)
        }

        @Test func iosSceneReceiveInputsRoutesFilesAndPhotos() throws {
            let directory = try makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let model = makeModel(directory: directory)
            let scene = ConvertIOSScene(model: model)

            scene.receive([.photosAsset(identifier: "asset-1", isVideo: true)])
            #expect(model.selection == .photosVideos)

            scene.receive([.file(URL(filePath: "/tmp/nonexistent.mov"))])
            #expect(model.selection == .localFiles)
            model.library.cancelScan()
        }
    #endif
}
