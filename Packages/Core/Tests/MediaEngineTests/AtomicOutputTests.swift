import AVFoundation
import Foundation
import MediaTestSupport
import Testing

@testable import MediaEngine

@Suite struct AtomicOutputTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "atomic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func partialIsHiddenSiblingOfFinal() {
        let final = URL(filePath: "/tmp/dir/clip.mov")
        let partial = AtomicOutput.partialURL(for: final)
        #expect(partial.deletingLastPathComponent() == final.deletingLastPathComponent())
        #expect(partial.lastPathComponent.hasPrefix(".clip.mov.partial-"))
        #expect(partial != AtomicOutput.partialURL(for: final))
    }

    @Test func commitMovesPartialToFinal() throws {
        let dir = try directory()
        let final = dir.appending(path: "out.mov")
        let partial = AtomicOutput.partialURL(for: final)
        try Data("new".utf8).write(to: partial)
        try AtomicOutput.commit(partial: partial, to: final)
        #expect(try Data(contentsOf: final) == Data("new".utf8))
        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }

    @Test func commitRefusesExistingFinal() throws {
        let dir = try directory()
        let final = dir.appending(path: "out.mov")
        let existing = Data("keep me".utf8)
        try existing.write(to: final)
        let partial = AtomicOutput.partialURL(for: final)
        try Data("new".utf8).write(to: partial)
        #expect(throws: DownscaleError.outputExists) { try AtomicOutput.commit(partial: partial, to: final) }
        #expect(try Data(contentsOf: final) == existing)
        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }

    @Test func fallbackCommitsWhenExclusiveRenameIsUnsupported() throws {
        for unsupported in [ENOTSUP, EINVAL] {
            let dir = try directory()
            let final = dir.appending(path: "out.mov")
            let partial = AtomicOutput.partialURL(for: final)
            try Data("new".utf8).write(to: partial)
            try AtomicOutput.commit(partial: partial, to: final) { _, _ in unsupported }
            #expect(try Data(contentsOf: final) == Data("new".utf8))
            #expect(!FileManager.default.fileExists(atPath: partial.path))
        }
    }

    @Test func fallbackRefusesExistingFinal() throws {
        let dir = try directory()
        let final = dir.appending(path: "out.mov")
        try Data("keep me".utf8).write(to: final)
        let partial = AtomicOutput.partialURL(for: final)
        try Data("new".utf8).write(to: partial)
        #expect(throws: DownscaleError.outputExists) {
            try AtomicOutput.commit(partial: partial, to: final) { _, _ in ENOTSUP }
        }
        #expect(try Data(contentsOf: final) == Data("keep me".utf8))
        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }

    @Test(.timeLimit(.minutes(5))) func downscaleWritesNoFinalUntilDone() async throws {
        var options = ClipOptions()
        options.width = 1280
        options.height = 720
        let source = try await FixtureFactory.makeClip(options)
        let output = source.deletingLastPathComponent().appending(path: "output.mov")
        let observed = Mutex2<(finalExisted: Bool, hiddenPartials: Int)>((true, 0))
        var downscaler = VideoDownscaler()
        downscaler.beforeStartWriting = { partial in
            let dir = output.deletingLastPathComponent()
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            observed.set(
                (
                    FileManager.default.fileExists(atPath: output.path),
                    names.filter { $0.hasPrefix(".output.mov.partial-") && $0 == partial.lastPathComponent }.count
                ))
        }
        try await downscaler.downscale(
            source: source, output: output, spec: DownscaleSpec(targetShortSide: 360, averageBitRate: 2_000_000)
        ) { _ in }
        let seen = observed.get()
        #expect(!seen.finalExisted)
        #expect(seen.hiddenPartials == 1)
        #expect(FileManager.default.fileExists(atPath: output.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: output.deletingLastPathComponent().path)
        #expect(!names.contains { $0.contains(".partial-") })
    }

    // Full software-HEVC re-encode: too slow on the Simulator, whose encoder is not representative (a smoke encode stays).
    @Test(.timeLimit(.minutes(5)), .enabled(if: EncoderEnvironment.isRepresentative)) func keepSourceResolution()
        async throws
    {
        var options = ClipOptions()
        options.width = 1280
        options.height = 720
        options.hdr = .hlg
        let source = try await FixtureFactory.makeClip(options)
        let output = source.deletingLastPathComponent().appending(path: "output.mov")
        try await VideoDownscaler().downscale(
            source: source, output: output, spec: DownscaleSpec(targetShortSide: nil, averageBitRate: 4_000_000)
        ) { _ in }
        let track = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(size == CGSize(width: 1280, height: 720))
    }
}

/// Minimal lock-protected box for values the test seam writes from another context.
private final class Mutex2<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func set(_ new: Value) { lock.withLock { value = new } }
    func get() -> Value { lock.withLock { value } }
}
