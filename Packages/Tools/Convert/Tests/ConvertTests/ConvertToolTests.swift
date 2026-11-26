import AppCore
import Foundation
import PhotosLibrary
import Testing

@testable import Convert

@Suite struct ConvertToolTests {
    private func makeTool() -> ConvertTool {
        let directory = URL.temporaryDirectory.appending(path: "tool-\(UUID().uuidString)", directoryHint: .isDirectory)
        return ConvertTool(
            photoStore: FakePhotoStore(assets: []), pendingDeletions: PendingDeletions(directory: directory),
            workFolder: WorkFolder(root: directory))
    }

    @Test func theToolIsCalledConvertAndKeepsItsSavedIdentifiers() {
        let tool = makeTool()
        #expect(tool.title == "Convert")
        #expect(tool.id == "downscale-video")
        #expect(tool.jobKinds.map(\.toolID) == ["downscale-video", "downscale-video-photos"])
        #expect(tool.platforms == [.macOS, .iOS])
    }

    @Test func eachJobKindHasItsOwnRunnerAndAnUnknownKindHasNone() {
        let tool = makeTool()
        #expect(tool.runner(for: ConvertTool.fileKind) is ConvertRunner)
        #expect(tool.runner(for: ConvertTool.photosKind) is PhotosConvertRunner)
        #expect(tool.runner(for: "other-tool") == nil)
    }

    @Test func itAcceptsMoviesAndPhotosVideosOnly() {
        let tool = makeTool()
        #expect(tool.accepts(.file(URL(filePath: "/tmp/clip.mov"))))
        #expect(tool.accepts(.file(URL(filePath: "/tmp/clip.MP4"))))
        #expect(!tool.accepts(.file(URL(filePath: "/tmp/photo.heic"))))
        #expect(!tool.accepts(.file(URL(filePath: "/tmp/notes.txt"))))
        #expect(!tool.accepts(.file(URL(string: "https://example.com/clip.mov")!)))
        #expect(tool.accepts(.photosAsset(identifier: "id", isVideo: true)))
        #expect(!tool.accepts(.photosAsset(identifier: "id", isVideo: false)))
    }
}
