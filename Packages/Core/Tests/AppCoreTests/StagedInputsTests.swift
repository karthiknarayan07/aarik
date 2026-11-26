import Foundation
import Testing

@testable import AppCore

@Suite struct StagedInputsTests {
    private func makeDirectory() throws -> URL {
        let directory = URL.temporaryDirectory.appending(
            path: "staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    @Test func aCopyLivesInItsOwnFolderUnderTheStagingDirectory() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = StagedInputs(directory: directory)

        let url = try staged.stage(name: "clip.mov", data: Data("video".utf8))

        #expect(url.lastPathComponent == "clip.mov")
        #expect(UUID(uuidString: url.deletingLastPathComponent().lastPathComponent) != nil)
        #expect(try Data(contentsOf: url) == Data("video".utf8))
        #expect(staged.owns(url))
    }

    @Test func aNameCannotClimbOutOfItsFolder() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = StagedInputs(directory: directory)

        let url = try staged.stage(name: "../../escape.mov", data: Data("x".utf8))
        let empty = try staged.stage(name: "..", data: Data("x".utf8))

        #expect(url.lastPathComponent == "escape.mov")
        #expect(staged.owns(url))
        #expect(empty.lastPathComponent == "Video.mov")
        #expect(!exists(directory.deletingLastPathComponent().appending(path: "escape.mov")))
    }

    @Test func removingACopyRemovesItsFolderAndOnlyThat() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = StagedInputs(directory: directory)
        let first = try staged.stage(name: "a.mov", data: Data("a".utf8))
        let second = try staged.stage(name: "b.mov", data: Data("b".utf8))

        staged.remove(first)

        #expect(!exists(first))
        #expect(!exists(first.deletingLastPathComponent()))
        #expect(exists(second))
    }

    @Test func removeLeavesAnythingNotMadeHereAlone() throws {
        let directory = try makeDirectory()
        let outside = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: outside)
        }
        let staged = StagedInputs(directory: directory)
        let mine = outside.appending(path: "mine.mov")
        try Data("m".utf8).write(to: mine)
        // Directly in the directory, not in a uuid folder.
        let stray = directory.appending(path: "stray.mov")
        try Data("s".utf8).write(to: stray)
        // In a folder that isn't a uuid.
        let named = directory.appending(path: "Named", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: named, withIntermediateDirectories: true)
        let inNamed = named.appending(path: "n.mov")
        try Data("n".utf8).write(to: inNamed)

        for url in [mine, stray, inNamed, directory] { staged.remove(url) }

        #expect(exists(mine))
        #expect(exists(stray))
        #expect(exists(inNamed))
        #expect(exists(directory))
        #expect(!staged.owns(mine))
    }

    @Test func aSweepKeepsWhatAJobStillReadsAndRemovesTheRest() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = StagedInputs(directory: directory)
        let referenced = try staged.stage(name: "queued.mov", data: Data("q".utf8))
        let orphan = try staged.stage(name: "orphan.mov", data: Data("o".utf8))
        // Not a copy of ours: its name isn't a uuid, so a sweep never touches it.
        let foreign = directory.appending(path: "Keep", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)

        staged.sweep(keeping: [referenced, URL(filePath: "/somewhere/else.mov")])

        #expect(exists(referenced))
        #expect(!exists(orphan))
        #expect(!exists(orphan.deletingLastPathComponent()))
        #expect(exists(foreign))
        #expect(exists(directory))
    }

    @Test func sweepingAMissingDirectoryIsHarmless() {
        let staged = StagedInputs(directory: URL.temporaryDirectory.appending(path: "nope-\(UUID().uuidString)"))
        staged.sweep(keeping: [URL]())
        #expect(!staged.owns(URL(filePath: "/tmp/x.mov")))
    }

    @Test func appGroupRootUsesStagingFolderInsideContainer() throws {
        let container = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: container) }

        let staged = StagedInputs.appGroup(
            identifier: "group.example.app",
            containerURL: { id in
                id == "group.example.app" ? container : nil
            })

        #expect(staged?.directory == container.appending(path: "Staging", directoryHint: .isDirectory))
        #expect(StagedInputs.appGroup(identifier: "group.example.app", containerURL: { _ in nil }) == nil)
    }

    @Test func stagingStreamsLargeFile() throws {
        let directory = try makeDirectory()
        let outside = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: outside)
        }
        let staged = StagedInputs(directory: directory)
        let source = outside.appending(path: "large.mov")
        let chunkSize = 256 * 1024
        let totalChunks = 64  // 16 MB
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let writer = try FileHandle(forWritingTo: source)
        for index in 0..<totalChunks {
            let block = Data(repeating: UInt8(index & 0xFF), count: chunkSize)
            try writer.write(contentsOf: block)
        }
        try writer.close()

        var observedChunks: [Int] = []
        let copy = try staged.stage(copying: source, chunkSize: chunkSize) { bytes in
            observedChunks.append(bytes)
        }

        #expect(staged.owns(copy))
        #expect(copy.lastPathComponent == "large.mov")
        #expect(observedChunks.count == totalChunks)
        #expect(observedChunks.allSatisfy { $0 <= chunkSize })

        let attrs = try FileManager.default.attributesOfItem(atPath: copy.path)
        #expect((attrs[.size] as? NSNumber)?.intValue == totalChunks * chunkSize)

        let reader = try FileHandle(forReadingFrom: copy)
        defer { try? reader.close() }
        for index in 0..<totalChunks {
            let data = try reader.read(upToCount: chunkSize)
            #expect(data == Data(repeating: UInt8(index & 0xFF), count: chunkSize))
        }
    }

    @Test func stagingSkipsNonVideos() throws {
        let directory = try makeDirectory()
        let outside = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: outside)
        }
        let staged = StagedInputs(directory: directory)
        let mov = outside.appending(path: "clip.mov")
        let mp4 = outside.appending(path: "second.mp4")
        let jpg = outside.appending(path: "photo.jpg")
        let txt = outside.appending(path: "notes.txt")
        let folder = outside.appending(path: "Subfolder", directoryHint: .isDirectory)
        try Data("mov".utf8).write(to: mov)
        try Data("mp4".utf8).write(to: mp4)
        try Data("jpg".utf8).write(to: jpg)
        try Data("txt".utf8).write(to: txt)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let result = staged.stageVideos(from: [mov, jpg, txt, folder, mp4])

        #expect(result.staged.map(\.lastPathComponent) == ["clip.mov", "second.mp4"])
        #expect(result.skippedNonVideos == 3)
        #expect(result.failed == 0)
        #expect(staged.pendingFiles().count == 2)
    }

    @Test func stagingNeverFollowsSymlinks() throws {
        let directory = try makeDirectory()
        let outside = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: outside)
        }
        let staged = StagedInputs(directory: directory)

        let realVideo = outside.appending(path: "real.mov")
        try Data("real-video".utf8).write(to: realVideo)
        let symlinkVideo = outside.appending(path: "link.mov")
        try FileManager.default.createSymbolicLink(at: symlinkVideo, withDestinationURL: realVideo)

        #expect(throws: StagedInputError.symbolicLinkNotAllowed) {
            _ = try staged.stage(copying: symlinkVideo)
        }
        let batch = staged.stageVideos(from: [symlinkVideo])
        #expect(batch.staged.isEmpty)
        #expect(batch.failed == 1)
        #expect(staged.pendingFiles().isEmpty)

        // Symlinked UUID folder inside Staging must never be followed or have its target removed.
        let victimFolder = outside.appending(path: "VictimFolder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: victimFolder, withIntermediateDirectories: true)
        let victimFile = victimFolder.appending(path: "victim.mov")
        try Data("keep".utf8).write(to: victimFile)

        let linkedUUID = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: linkedUUID, withDestinationURL: victimFolder)

        // Symlinked file inside a real UUID folder must also be ignored and its target untouched.
        let realUUID = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: realUUID, withIntermediateDirectories: true)
        let linkedFile = realUUID.appending(path: "alias.mov")
        try FileManager.default.createSymbolicLink(at: linkedFile, withDestinationURL: victimFile)

        #expect(!staged.owns(linkedUUID.appending(path: "victim.mov")))
        #expect(!staged.owns(linkedFile))
        #expect(staged.pendingFiles().isEmpty)

        staged.remove(linkedFile)
        staged.sweep(keeping: [URL]())
        #expect(exists(victimFile))

        // A symlinked staging root must also refuse writes and sweeps.
        let linkedRoot = outside.appending(path: "StagingLink", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: victimFolder)
        let symlinkStore = StagedInputs(directory: linkedRoot)
        #expect(throws: StagedInputError.symbolicLinkNotAllowed) {
            _ = try symlinkStore.stage(copying: realVideo)
        }
        #expect(throws: StagedInputError.symbolicLinkNotAllowed) {
            _ = try symlinkStore.stage(name: "x.mov", data: Data("x".utf8))
        }
        symlinkStore.sweep(keeping: [URL]())
        #expect(exists(victimFile))
    }

    @Test func pendingFilesSkipsHiddenPartialsAndTrackedURLs() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = StagedInputs(directory: directory)
        let first = try staged.stage(name: "first.mov", data: Data("1".utf8))
        let second = try staged.stage(name: "second.mov", data: Data("2".utf8))

        let inProgressFolder = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: inProgressFolder, withIntermediateDirectories: true)
        let partial = inProgressFolder.appending(path: ".video.mov.partial-\(UUID().uuidString)")
        try Data("partial".utf8).write(to: partial)

        let pending = staged.pendingFiles(excluding: [first])
        #expect(pending.map(\.lastPathComponent) == ["second.mov"])
        #expect(pending.first?.standardizedFileURL == second.standardizedFileURL)
    }
}
