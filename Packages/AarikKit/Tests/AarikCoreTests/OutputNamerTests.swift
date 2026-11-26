import Foundation
import Testing

@testable import AarikCore

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("OutputNamerTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func namerReturnsPlainNameWhenFree() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = OutputNamer.url(
        for: URL(fileURLWithPath: "/x/a.mov"), label: "1080p", in: dir)
    #expect(url == dir.appendingPathComponent("a (1080p).mov"))
}

@Test func namerSkipsExisting() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data().write(to: dir.appendingPathComponent("a (1080p).mov"))
    let source = URL(fileURLWithPath: "/x/a.mov")
    #expect(
        OutputNamer.url(for: source, label: "1080p", in: dir)
            == dir.appendingPathComponent("a (1080p) 2.mov"))
    try Data().write(to: dir.appendingPathComponent("a (1080p) 2.mov"))
    #expect(
        OutputNamer.url(for: source, label: "1080p", in: dir)
            == dir.appendingPathComponent("a (1080p) 3.mov"))
}

@Test func namerTreatsDanglingSymlinkAsTaken() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createSymbolicLink(
        at: dir.appendingPathComponent("a (1080p).mov"),
        withDestinationURL: dir.appendingPathComponent("missing-target"))
    let url = OutputNamer.url(
        for: URL(fileURLWithPath: "/x/a.mov"), label: "1080p", in: dir)
    #expect(url == dir.appendingPathComponent("a (1080p) 2.mov"))
}

@Test func namerHandlesMissingExtension() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data().write(to: dir.appendingPathComponent("notes (small)"))
    let url = OutputNamer.url(
        for: URL(fileURLWithPath: "/x/notes"), label: "small", in: dir)
    #expect(url == dir.appendingPathComponent("notes (small) 2"))
}

@Test func copyNameKeepsTheOriginalNameWhenFree() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = URL(fileURLWithPath: "/x/IMG 1.mov")
    #expect(OutputNamer.url(keepingNameOf: source, in: dir) == dir.appendingPathComponent("IMG 1.mov"))
    try Data().write(to: dir.appendingPathComponent("IMG 1.mov"))
    #expect(OutputNamer.url(keepingNameOf: source, in: dir) == dir.appendingPathComponent("IMG 1 2.mov"))
    try Data().write(to: dir.appendingPathComponent("IMG 1 2.mov"))
    #expect(OutputNamer.url(keepingNameOf: source, in: dir) == dir.appendingPathComponent("IMG 1 3.mov"))
}

@Test func namerUsesAnotherExtensionWhenTheContainerChanges() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = URL(fileURLWithPath: "/x/IMG_1.m4v")
    #expect(
        OutputNamer.url(for: source, label: "1080p", in: dir, pathExtension: "mov")
            == dir.appendingPathComponent("IMG_1 (1080p).mov"))
    try Data().write(to: dir.appendingPathComponent("IMG_1 (1080p).mov"))
    #expect(
        OutputNamer.url(for: source, label: "1080p", in: dir, pathExtension: "mov")
            == dir.appendingPathComponent("IMG_1 (1080p) 2.mov"))
}
