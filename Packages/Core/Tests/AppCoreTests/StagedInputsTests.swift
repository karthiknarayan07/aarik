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
}
