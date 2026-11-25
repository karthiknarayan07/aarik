import Foundation
import Testing

@testable import PhotosLibrary

@Suite struct WorkFolderTests {
    /// A fresh temporary parent holding `Work` and a bystander folder beside it.
    private func fixture() throws -> (parent: URL, work: WorkFolder, bystander: URL) {
        let parent = FileManager.default.temporaryDirectory.appending(
            path: "WorkFolderTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let bystander = parent.appending(path: "Other", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bystander, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: bystander.appending(path: "keep.txt"))
        return (parent, WorkFolder(root: parent.appending(path: "Work", directoryHint: .isDirectory)), bystander)
    }

    @Test func createsAFolderPerJob() throws {
        let (parent, work, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        let id = UUID()
        let folder = try work.create(for: id)
        #expect(folder == work.url(for: id))
        #expect(FileManager.default.fileExists(atPath: folder.path))
        #expect(folder.deletingLastPathComponent().lastPathComponent == "Work")
    }

    @Test func removesOneJobAndLeavesOthers() throws {
        let (parent, work, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        let one = try work.create(for: UUID())
        let two = try work.create(for: UUID())
        try Data("x".utf8).write(to: one.appending(path: "input.mov"))
        work.remove(one)
        #expect(!FileManager.default.fileExists(atPath: one.path))
        #expect(FileManager.default.fileExists(atPath: two.path))
    }

    @Test func removingTwiceOrAMissingJobIsFine() throws {
        let (parent, work, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        let id = UUID()
        try work.create(for: id)
        work.remove(jobID: id)
        work.remove(jobID: id)
        work.remove(jobID: UUID())
    }

    @Test func sweepClearsEveryJobButKeepsTheFolderAndNeighbours() throws {
        let (parent, work, bystander) = try fixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        let one = try work.create(for: UUID())
        try Data("x".utf8).write(to: one.appending(path: "input.mov"))
        try work.create(for: UUID())
        try Data("stray".utf8).write(to: work.root.appending(path: "stray.tmp"))
        work.sweep()
        #expect(FileManager.default.fileExists(atPath: work.root.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: work.root.path).isEmpty)
        #expect(FileManager.default.fileExists(atPath: bystander.appending(path: "keep.txt").path))
    }

    @Test func sweepWithoutAWorkFolderIsFine() throws {
        let (parent, work, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        work.sweep()
        #expect(!FileManager.default.fileExists(atPath: work.root.path))
    }

    @Test func neverRemovesOutsideTheWorkFolder() throws {
        let (parent, work, bystander) = try fixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        try work.create(for: UUID())
        work.remove(bystander)
        work.remove(work.root)
        work.remove(work.root.appending(path: "../Other"))
        work.remove(parent)
        #expect(FileManager.default.fileExists(atPath: bystander.appending(path: "keep.txt").path))
        #expect(FileManager.default.fileExists(atPath: work.root.path))
    }

    @Test func aSymbolicLinkOutOfTheWorkFolderIsNotFollowed() throws {
        let (parent, work, bystander) = try fixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: work.root, withIntermediateDirectories: true)
        let link = work.root.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bystander)
        work.remove(link)
        #expect(FileManager.default.fileExists(atPath: bystander.appending(path: "keep.txt").path))
    }

    @Test func standardFolderIsUnderApplicationSupportForTheBundle() {
        let work = WorkFolder.standard(bundleIdentifier: "com.example.app")
        #expect(work.root.path.hasSuffix("/com.example.app/Work"))
        #expect(work.root.path.contains("Application Support"))
    }
}
