import AppCore
import AppServices
import Foundation
import MediaTestSupport
import PhotosLibrary
import Testing

@testable import Convert

private struct MacOnlyFakeTool: Tool {
    let id = "mac-only"
    let title = "Mac Only"
    let systemImage = "macbook"
    var platforms: ToolPlatforms { .macOS }
}

@Suite struct IOSDestinationAndDocumentsTests {
    private func makeDirectory() throws -> URL {
        let directory = URL.temporaryDirectory.appending(
            path: "ios-dest-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func iosSaveLocationDefaultsToDocumentsAndDisablesReplace() {
        let location = SaveLocation(platform: .iOS)
        #expect(location.choice == .documents)
        #expect(location.destination == .documents)
        #expect(SaveLocation.defaultChoice(for: .iOS) == .documents)
        #expect(SaveLocation.availableChoices(for: .iOS) == [.documents, .folder])
        #expect(!SaveLocation.allowsReplace(for: .iOS))

        #expect(SaveLocation.defaultChoice(for: .macOS) == .nextToOriginal)
        #expect(SaveLocation.availableChoices(for: .macOS) == [.nextToOriginal, .folder, .replace])
        #expect(SaveLocation.allowsReplace(for: .macOS))
    }

    @Test func iosDefaultSaveLocationIgnoresNextToOriginalAndReplaceDefaults() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = UserDefaults(suiteName: "IOSDestTests-\(UUID().uuidString)")!

        defaults.set(SaveLocation.Choice.nextToOriginal.rawValue, forKey: AppSettings.Keys.defaultSaveTo)
        #expect(AppSettings.defaultSaveLocation(defaults, platform: .iOS).choice == .documents)

        defaults.set(SaveLocation.Choice.replace.rawValue, forKey: AppSettings.Keys.defaultSaveTo)
        #expect(AppSettings.defaultSaveLocation(defaults, platform: .iOS).choice == .documents)

        var folderLocation = SaveLocation(platform: .iOS)
        try folderLocation.setFolder(directory)
        defaults.set(SaveLocation.Choice.folder.rawValue, forKey: AppSettings.Keys.defaultSaveTo)
        defaults.set(folderLocation.folderBookmark, forKey: AppSettings.Keys.defaultSaveFolder)

        let resolved = AppSettings.defaultSaveLocation(defaults, platform: .iOS)
        #expect(resolved.choice == .folder)
        if case .folder = resolved.destination {
        } else {
            Issue.record("expected .folder destination, got \(String(describing: resolved.destination))")
        }
    }

    @Test func saveDestinationDocumentsRoundTripsThroughJSON() throws {
        let original = ConvertJobSettings(preset: .balanced, saveTo: .documents)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ConvertJobSettings.self, from: data)
        #expect(decoded.saveTo == .documents)
    }

    @Test func outputFolderForDocumentsUsesInjectedDocumentsDirectoryAndCreatesIt() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "inbox/clip.mov")
        let docs = root.appending(path: "Documents", directoryHint: .isDirectory)

        let resolved = try ConvertRunner.outputFolder(
            for: .documents, source: source, documentsDirectory: { docs })
        defer { resolved.stop() }

        #expect(resolved.url.standardizedFileURL == docs.standardizedFileURL)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: docs.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test(.timeLimit(.minutes(5)), .enabled(if: EncoderEnvironment.isRepresentative))
    func runnerDocumentsDestinationWritesOutputIntoDocumentsDirectory() async throws {
        let source = try await RunnerFixture.source(name: "inbox.mov")
        let sourceDir = source.deletingLastPathComponent()
        let docsDir = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: sourceDir)
            try? FileManager.default.removeItem(at: docsDir)
        }
        let runner = ConvertRunner(
            trash: ConvertRunner.trashItem, documentsDirectory: { docsDir }, diskSpace: RunnerFixture.roomy)
        let settings = ConvertJobSettings(preset: .balanced, saveTo: .documents, custom: RunnerFixture.spec)

        let state = try await runner.run(try RunnerFixture.job(source, settings)) { _ in }

        guard case .completed(let outcome) = state else {
            Issue.record("expected completed, got \(state)")
            return
        }
        #expect(
            outcome.output.deletingLastPathComponent().resolvingSymlinksInPath() == docsDir.resolvingSymlinksInPath())
        #expect(outcome.output.lastPathComponent == "inbox (1080p).mov")
        #expect(!outcome.replacedOriginal)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func iosToolRegistryFiltersOutMacOnlyToolsAndKeepsConvert() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let convert = ConvertTool(
            photoStore: FakePhotoStore(), pendingDeletions: PendingDeletions(directory: directory),
            workFolder: WorkFolder(root: directory))
        let filtered = ToolRegistry.tools(for: .iOS, from: [convert, MacOnlyFakeTool()])
        #expect(filtered.map(\.id) == [ConvertTool.toolID])
    }

    #if os(iOS)
        @MainActor
        @Test func iosConvertModelDefaultsToDocumentsAndRefusesFileReplace() throws {
            let directory = try makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let defaults = UserDefaults(suiteName: "IOSModelTests-\(UUID().uuidString)")!
            let services = AppServices(directory: directory, defaults: defaults, photoStore: FakePhotoStore())
            let model = ConvertModel(services: services)

            #expect(model.saveLocation.choice == .documents)
            #expect(model.effectiveFileDestination == .documents)

            model.saveLocation.choice = .replace
            #expect(model.effectiveFileDestination == .documents)
        }
    #endif
}
