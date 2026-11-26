import AppCore
import Foundation
import MediaEngine
import MediaTestSupport
import Testing

@testable import Convert

@Suite struct H264PlannerTests {
    private func item(_ key: String, _ value: String) -> MetadataItem {
        MetadataItem(
            key: key, category: key.hasPrefix("hdr.") ? .hdr : .video, displayName: key, value: value)
    }

    private var hlgInventory: MetadataInventory {
        MetadataInventory(items: [
            item("video.dimensions", "3840x2160"), item("video.frameRate", "30.00"), item("video.duration", "60000"),
            item("video.codec", "hvc1"), item("video.colorPrimaries", "ITU_R_2020"),
            item("video.transferFunction", "ITU_R_2100_HLG"), item("video.matrix", "ITU_R_2020"),
            item("video.bitDepth", "10"), item("hdr.dolbyVision", "profile 8, level 9, compat 4"),
            item("hdr.masteringDisplay", "33c2"), item("hdr.contentLightLevel", "03e8"),
            item("hdr.ambientViewingEnvironment", "0004"),
        ])
    }

    private func predicted(_ inventory: MetadataInventory, codec: VideoCodec) throws -> MetadataReport {
        let spec = DownscaleSpec(targetShortSide: 1080, averageBitRate: 16_000_000, codec: codec)
        let decision = ConvertPlanner.decide(inventory: inventory, byteSize: 600_000_000, spec: spec)
        guard case .convert(_, _, let report) = decision else {
            Issue.record("expected convert, got \(decision)")
            throw CancellationError()
        }
        return report
    }

    @Test func plannerPredictsHDRLossForH264() throws {
        let report = try predicted(hlgInventory, codec: .h264Compatible)
        #expect(
            report.lost.map(\.key)
                == [
                    "hdr.dolbyVision", "hdr.masteringDisplay", "hdr.contentLightLevel", "hdr.ambientViewingEnvironment",
                ])
        let changed = Dictionary(uniqueKeysWithValues: report.changed.map { ($0.key, $0.to) })
        #expect(
            changed == [
                "video.dimensions": "1920x1080", "video.codec": "avc1", "video.colorPrimaries": "ITU_R_709_2",
                "video.transferFunction": "ITU_R_709_2", "video.matrix": "ITU_R_709_2", "video.bitDepth": "8",
            ])
        #expect(report.kept.map(\.key) == ["video.frameRate", "video.duration"])
    }

    @Test func plannerKeepsHDRForHEVC() throws {
        let report = try predicted(hlgInventory, codec: .hevcKeepHDR)
        #expect(report.lost.isEmpty)
        #expect(Set(report.changed.map(\.key)) == ["video.dimensions", "hdr.dolbyVision"])
    }

    @Test func h264FromAn8BitSDRSourceOnlyChangesTheCodec() throws {
        let sdr = MetadataInventory(items: [
            item("video.dimensions", "3840x2160"), item("video.frameRate", "30.00"), item("video.duration", "60000"),
            item("video.codec", "hvc1"), item("video.colorPrimaries", "ITU_R_709_2"),
            item("video.transferFunction", "ITU_R_709_2"), item("video.matrix", "ITU_R_709_2"),
            item("video.bitDepth", "8"),
        ])
        let report = try predicted(sdr, codec: .h264Compatible)
        #expect(report.lost.isEmpty)
        #expect(Set(report.changed.map(\.key)) == ["video.dimensions", "video.codec"])
    }

    @Test func formatPickerPrefillsTheH264BitRateOnlyWhenUntouched() {
        var options = AdvancedOptions()
        #expect(options.codec == .hevcKeepHDR)
        options.codec = .h264Compatible
        #expect(options.bitRateMbps == 16)
        options.codec = .hevcKeepHDR
        #expect(options.bitRateMbps == 10)
        options.bitRateMbps = 12
        options.codec = .h264Compatible
        #expect(options.bitRateMbps == 12)
        options.isEnabled = true
        #expect(options.spec?.codec == .h264Compatible)
        #expect(VideoCodec.allCases.map(\.title) == ["HEVC (keeps HDR)", "H.264 (most compatible)"])
    }

    @Test func jobSettingsWithoutACodecStillDecode() throws {
        let json = Data(
            #"{"preset":"balanced","saveTo":{"nextToOriginal":{}},"custom":{"targetShortSide":720,"averageBitRate":5000000}}"#
                .utf8)
        let settings = try JSONDecoder().decode(ConvertJobSettings.self, from: json)
        #expect(settings.custom?.codec == .hevcKeepHDR)
    }

    @Test(.timeLimit(.minutes(3))) func replaceWorksForH264FromHLG() async throws {
        var options = ClipOptions()
        options.width = 2560
        options.height = 1440
        options.fps = 10
        options.hdr = .hlg
        options.videoBitRate = 20_000_000
        options.contentLightLevel = Data([0x03, 0xE8, 0x01, 0x90])
        let clip = try await FixtureFactory.makeClip(options)
        let directory = clip.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let trash = directory.appending(path: "Trash", directoryHint: .isDirectory)
        let runner = ConvertRunner(
            trash: { url in
                try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
                let destination = trash.appending(path: url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: destination)
                return destination
            },
            diskSpace: RunnerFixture.roomy)
        // The synthetic HLG clip compresses to about 1.1 Mbps, so the H.264 output needs a lower rate to save over 10%.
        let spec = DownscaleSpec(targetShortSide: 1080, averageBitRate: 300_000, codec: .h264Compatible)
        let settings = ConvertJobSettings(preset: .balanced, saveTo: .replace, custom: spec)

        let state = try await runner.run(try RunnerFixture.job(clip, settings)) { _ in }

        guard case .completed(let outcome) = state else {
            Issue.record("expected completed, got \(state), source \(RunnerFixture.size(clip) ?? -1) bytes")
            return
        }
        #expect(outcome.warnings.isEmpty, "\(outcome.warnings)")
        #expect(outcome.replacedOriginal)
        #expect(outcome.output == clip)
        let inventory = try await MediaInspector().inventory(of: clip)
        #expect(inventory["video.codec"]?.value == "avc1")
        #expect(Set(outcome.report.lost.map(\.key)).isSuperset(of: ["hdr.dolbyVision", "hdr.contentLightLevel"]))
    }
}

@Suite struct StalePartialSweepTests {
    @Test func onlyRealUUIDPartialFilesAreRemoved() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let real = directory.appending(path: ".clip.mov.partial-\(UUID().uuidString)")
        let lookalike = directory.appending(path: ".clip.mov.partial-notauuid")
        let folder = directory.appending(path: ".clip.mov.partial-\(UUID().uuidString)", directoryHint: .isDirectory)
        try Data("half".utf8).write(to: real)
        try Data("mine".utf8).write(to: lookalike)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: folder.appending(path: "keep.txt"))

        ConvertRunner.removeStalePartials(of: directory.appending(path: "clip.mov"))

        #expect(!FileManager.default.fileExists(atPath: real.path))
        #expect(FileManager.default.fileExists(atPath: lookalike.path))
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "keep.txt").path))
    }
}
