import Foundation
import Testing

@testable import AarikCore

@Suite struct ImportDropGuardTests {
    private let temp = URL(filePath: "/private/var/folders/xx/T", directoryHint: .isDirectory)

    @Test func filesFromElsewhereAreImportable() {
        let urls = [URL(filePath: "/Users/me/Movies/a.mov"), URL(filePath: "/Volumes/Card/b.mov")]
        #expect(ImportDropGuard.importable(urls, isInternalDragActive: false, temporaryDirectories: [temp]) == urls)
    }

    @Test func aDragThatStartedInTheGridIsNeverAnImport() {
        let urls = [URL(filePath: "/Users/me/Movies/a.mov")]
        #expect(ImportDropGuard.importable(urls, isInternalDragActive: true, temporaryDirectories: [temp]).isEmpty)
    }

    @Test func theCopyMadeForADragInTheTemporaryDirectoryIsNotImported() {
        let copy = temp.appending(path: "drag-123/a.mov")
        let real = URL(filePath: "/Users/me/Movies/b.mov")
        #expect(
            ImportDropGuard.importable([copy, real], isInternalDragActive: false, temporaryDirectories: [temp])
                == [real])
    }

    @Test func aSiblingFolderWithTheSamePrefixIsNotTheTemporaryDirectory() {
        let other = URL(filePath: "/private/var/folders/xx/Tools/a.mov")
        #expect(
            ImportDropGuard.importable([other], isInternalDragActive: false, temporaryDirectories: [temp]) == [other])
    }
}
