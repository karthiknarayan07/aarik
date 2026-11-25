import AVFoundation
import AppCore
import Foundation
import MediaEngine
import MediaTestSupport
import Synchronization
import Testing

@testable import DownscaleVideo

/// An MPEG-4 source that has to be written as QuickTime: what that loses is predicted and shown before the run,
/// anything more is never a silent loss, and the job says why its file has another name.
@Suite struct ContainerFallbackRunnerTests {
    private let spec = RunnerFixture.spec

    private func item(_ key: String, _ value: String) -> MetadataItem {
        MetadataItem(key: key, category: .other, displayName: key, value: value)
    }

    private var inventory: MetadataInventory {
        MetadataInventory(items: [
            item("video.dimensions", "3840x2160"), item("video.frameRate", "30.00"), item("video.duration", "60000"),
            MetadataItem(key: "qt.uiso/loci", category: .location, displayName: "Location", value: "+1+2/"),
            item("qt.itsk/©mak", "Apple"),
        ])
    }

    private let byteSize = Int64(60_000_000 * 60 / 8)

    // MARK: - Prediction

    @Test func plannerPredictsWhatTheQuickTimeFallbackLoses() throws {
        let decision = DownscalePlanner.decide(
            inventory: inventory, byteSize: byteSize, spec: spec, fallsBackToQuickTime: true)
        guard case .convert(_, _, let predicted) = decision else {
            Issue.record("expected convert, got \(decision)")
            return
        }
        #expect(predicted.lost.map(\.key) == ["qt.uiso/loci"])
        #expect(!predicted.kept.contains { $0.key == "qt.uiso/loci" })

        let same = DownscalePlanner.decide(inventory: inventory, byteSize: byteSize, spec: spec)
        guard case .convert(_, _, let samePredicted) = same else {
            Issue.record("expected convert, got \(same)")
            return
        }
        #expect(samePredicted.lost.isEmpty)
    }

    @Test func lossCheckNamesWhatTheQuickTimeFallbackLoses() {
        #expect(
            LossCheck.lostNames(
                byteSize: byteSize, inventory: inventory, preset: .balanced, custom: spec, fallsBackToQuickTime: true)
                == ["Location"])
        #expect(LossCheck.lostNames(byteSize: byteSize, inventory: inventory, preset: .balanced, custom: spec).isEmpty)
        let losses = LossCheck.losses(
            for: [(id: 1, source: (byteSize, inventory)), (id: 2, source: (byteSize, inventory))], preset: .balanced,
            custom: spec, quickTimeFallbacks: [2])
        #expect(losses == [PredictedLoss(id: 2, lost: ["Location"])])
    }

    @Test(.timeLimit(.minutes(2))) func containerFallbacksAreFoundForTheFilesThatNeedThem() async throws {
        let m4v = try await RunnerFixture.source(name: "a.m4v", fileType: .mp4, timedMetadata: true)
        let mov = try await RunnerFixture.source(name: "b.mov")
        defer {
            for url in [m4v, mov] { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        }
        let missing = URL(filePath: "/nonexistent/c.mp4")

        let found = await LossCheck.quickTimeFallbacks(among: [
            (id: 1, url: m4v), (id: 2, url: mov), (id: 3, url: missing),
        ])

        #expect(found == [1])
    }

    // MARK: - Runs

    @Test(.timeLimit(.minutes(2))) func predictedFallbackLossIsVerifiedAndExplained() async throws {
        let source = try await RunnerFixture.source(
            name: "x.m4v", fileType: .mp4, timedMetadata: true, metadata: RunnerFixture.locationMetadata)
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = DownscaleJobSettings(preset: .balanced, saveTo: .nextToOriginal, custom: spec)

        let state = try await DownscaleRunner().run(try RunnerFixture.job(source, settings)) { _ in }

        guard case .completed(let outcome) = state else {
            Issue.record("expected completed, got \(state)")
            return
        }
        #expect(outcome.output.lastPathComponent == "x (1080p).mov")
        #expect(outcome.report.lost.contains { $0.key == "qt.uiso/loci" })
        #expect(outcome.isVerified)
        #expect(outcome.notes == ["Saved as a .mov file because M4V can't hold all of its tracks"])
    }

    @Test(.timeLimit(.minutes(2)), arguments: [SaveDestination.nextToOriginal, .replace])
    func unpredictedLossInAnotherContainerKeepsTheOriginalAsIs(_ destination: SaveDestination) async throws {
        let source = try await RunnerFixture.source(name: "x.m4v", fileType: .mp4, timedMetadata: true)
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        // The QuickTime output turns out to lack something nobody predicted.
        let runner = DownscaleRunner(
            trash: { _ in throw CocoaError(.fileWriteNoPermission) },
            inspect: { url in
                var inventory = try await MediaInspector().inventory(of: url)
                let audioKeys = Set(inventory.items.map(\.key).filter { $0.hasPrefix("audio.") })
                guard !audioKeys.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                inventory.items.removeAll { audioKeys.contains($0.key) }
                return inventory
            })
        let settings = DownscaleJobSettings(preset: .balanced, saveTo: destination, custom: spec)

        let state = try await runner.run(try RunnerFixture.job(source, settings)) { _ in }

        #expect(state == .keptAsIs(reason: "Its file format can't keep all of its details"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [source.lastPathComponent])
    }

    @Test(.timeLimit(.minutes(2))) func replaceUnderATakenNameSaysWhy() async throws {
        let source = try await RunnerFixture.source(name: "x.m4v", fileType: .mp4, timedMetadata: true)
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let taken = directory.appending(path: "x.mov")
        try Data("someone else's file".utf8).write(to: taken)
        let runner = DownscaleRunner(trash: { url in
            let trashed = directory.appending(path: "trashed-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: url, to: trashed)
            return trashed
        })
        let settings = DownscaleJobSettings(preset: .balanced, saveTo: .replace, custom: spec)

        let state = try await runner.run(try RunnerFixture.job(source, settings)) { _ in }

        guard case .completed(let outcome) = state else {
            Issue.record("expected completed, got \(state)")
            return
        }
        #expect(outcome.replacedOriginal)
        #expect(outcome.output.lastPathComponent == "x (1080p).mov")
        #expect(
            outcome.notes == [
                "Saved as a .mov file because M4V can't hold all of its tracks",
                "Saved as “x (1080p).mov” because “x.mov” already exists",
            ])
        #expect(outcome.warnings.isEmpty)
        #expect(try Data(contentsOf: taken) == Data("someone else's file".utf8))
    }

    @Test(.timeLimit(.minutes(2))) func sameContainerRunHasNoNotes() async throws {
        let source = try await RunnerFixture.source()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let settings = DownscaleJobSettings(preset: .balanced, saveTo: .nextToOriginal, custom: spec)

        let state = try await DownscaleRunner().run(try RunnerFixture.job(source, settings)) { _ in }

        guard case .completed(let outcome) = state else {
            Issue.record("expected completed, got \(state)")
            return
        }
        #expect(outcome.notes.isEmpty)
    }

    // MARK: - Our output never outlives a failed check

    @Test(.timeLimit(.minutes(2))) func failingToInspectTheOutputRemovesIt() async throws {
        let source = try await RunnerFixture.source()
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = DownscaleRunner(
            trash: { _ in throw CocoaError(.fileWriteNoPermission) },
            inspect: { _ in throw CocoaError(.fileReadCorruptFile) })
        let settings = DownscaleJobSettings(preset: .balanced, saveTo: .nextToOriginal, custom: spec)

        await #expect(throws: CocoaError.self) {
            _ = try await runner.run(try RunnerFixture.job(source, settings)) { _ in }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [source.lastPathComponent])
    }

    @Test(.timeLimit(.minutes(2))) func failingToMeasureTheOutputRemovesIt() async throws {
        let source = try await RunnerFixture.source()
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = DownscaleRunner(
            trash: { _ in throw CocoaError(.fileWriteNoPermission) },
            sizeOf: { _ in throw CocoaError(.fileReadUnknown) })
        let settings = DownscaleJobSettings(preset: .balanced, saveTo: .nextToOriginal, custom: spec)

        await #expect(throws: CocoaError.self) {
            _ = try await runner.run(try RunnerFixture.job(source, settings)) { _ in }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [source.lastPathComponent])
    }

    @Test(.timeLimit(.minutes(2))) func cancelledWhileInspectingTheOutputRemovesIt() async throws {
        let source = try await RunnerFixture.source()
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = DownscaleRunner(
            trash: { _ in throw CocoaError(.fileWriteNoPermission) },
            inspect: { _ in throw CancellationError() })
        let settings = DownscaleJobSettings(preset: .balanced, saveTo: .nextToOriginal, custom: spec)

        await #expect(throws: CancellationError.self) {
            _ = try await runner.run(try RunnerFixture.job(source, settings)) { _ in }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [source.lastPathComponent])
    }

    // MARK: - The file the run used

    @Test(.timeLimit(.minutes(2))) func outcomeRecordsTheFileTheRunActuallyRead() async throws {
        let original = try await RunnerFixture.source()
        let directory = original.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bookmark = try original.bookmarkData()
        // The file moved after it was added; its bookmark still finds it.
        let moved = directory.appending(path: "moved.mov")
        try FileManager.default.moveItem(at: original, to: moved)
        let settings = DownscaleJobSettings(preset: .balanced, saveTo: .nextToOriginal, custom: spec)
        let job = Job(
            toolID: DownscaleTool.toolID, source: original, sourceBookmark: bookmark,
            settings: try JSONEncoder().encode(settings))

        let state = try await DownscaleRunner().run(job) { _ in }

        guard case .completed(let outcome) = state else {
            Issue.record("expected completed, got \(state)")
            return
        }
        #expect(outcome.source?.standardizedFileURL.resolvingSymlinksInPath() == moved.resolvingSymlinksInPath())
    }
}
