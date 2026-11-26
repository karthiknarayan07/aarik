import AVFoundation
import AppCore
import Foundation
import MediaEngine
import MediaTestSupport
import Synchronization
import Testing

@testable import Convert

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
        let decision = ConvertPlanner.decide(
            inventory: inventory, byteSize: byteSize, spec: spec, fallsBackToQuickTime: true)
        guard case .convert(_, _, let predicted) = decision else {
            Issue.record("expected convert, got \(decision)")
            return
        }
        #expect(predicted.lost.map(\.key) == ["qt.uiso/loci"])
        #expect(!predicted.kept.contains { $0.key == "qt.uiso/loci" })

        let same = ConvertPlanner.decide(inventory: inventory, byteSize: byteSize, spec: spec)
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
        #expect(losses == [PredictedLoss(id: 2, lost: ["Location"], keys: ["qt.uiso/loci"])])
    }

    /// Inventories read before ISO user data had names call it "loci"; it is named by its key all the same.
    @Test func lossCheckNamesIsoUserDataByItsKey() {
        let old = MetadataInventory(
            items: inventory.items.map { item in
                item.key == "qt.uiso/loci"
                    ? MetadataItem(key: item.key, category: .other, displayName: "loci", value: item.value) : item
            })
        #expect(
            LossCheck.lostNames(
                byteSize: byteSize, inventory: old, preset: .balanced, custom: spec, fallsBackToQuickTime: true)
                == ["Location"])
    }

    @Test(.timeLimit(.minutes(5))) func containerFallbacksAreFoundForTheFilesThatNeedThem() async throws {
        let m4v = try await RunnerFixture.source(name: "a.m4v", fileType: .mp4, timedMetadata: true)
        let mov = try await RunnerFixture.source(name: "b.mov")
        defer {
            for url in [m4v, mov] { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        }
        let missing = URL(filePath: "/nonexistent/c.mp4")
        let missingMOV = URL(filePath: "/nonexistent/d.mov")

        let found = await LossCheck.quickTimeFallbacks(among: [
            (id: 1, url: m4v), (id: 2, url: mov), (id: 3, url: missing), (id: 4, url: missingMOV),
        ])

        // An MPEG-4 file that can't be read counts as falling back, so its loss is shown rather than missed.
        #expect(found == [1, 3])
    }

    // MARK: - Runs

    @Test(.timeLimit(.minutes(5))) func predictedFallbackLossIsVerifiedAndExplained() async throws {
        let source = try await RunnerFixture.source(
            name: "x.m4v", fileType: .mp4, timedMetadata: true, metadata: RunnerFixture.locationMetadata)
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        // What the sheet showed before the job was added.
        let settings = ConvertJobSettings(
            preset: .balanced, saveTo: .nextToOriginal, custom: spec, predictedLost: ["Location", "Creation date"])

        let state = try await RunnerFixture.runner().run(try RunnerFixture.job(source, settings)) { _ in }

        guard case .completed(let outcome) = state else {
            Issue.record("expected completed, got \(state)")
            return
        }
        #expect(outcome.output.lastPathComponent == "x (1080p).mov")
        #expect(outcome.report.lost.contains { $0.key == "qt.uiso/loci" })
        #expect(outcome.isVerified)
        #expect(outcome.notes == ["Saved as a .mov file because M4V can't hold all of its tracks"])
        #expect(outcome.noteCodes == [.containerChanged])
    }

    /// Regression: a library entry read before ISO user data had names ("loci") still gets a job whose fallback
    /// loss counts as shown, so it converts and is verified instead of being kept as is.
    @Test(.timeLimit(.minutes(5))) func fallbackShownFromAnOldInventoryIsVerified() async throws {
        let source = try await RunnerFixture.source(
            name: "x.m4v", fileType: .mp4, timedMetadata: true, metadata: RunnerFixture.locationMetadata)
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fresh = try await MediaInspector().inventory(of: source)
        let old = MetadataInventory(
            items: fresh.items.map { item in
                guard item.key.hasPrefix("qt.uiso/") else { return item }
                let code = String(item.key.dropFirst("qt.uiso/".count))
                return MetadataItem(key: item.key, category: .other, displayName: code, value: item.value)
            })
        let size = try #require(RunnerFixture.size(source))
        let loss = try #require(
            LossCheck.losses(
                for: [(id: 1, source: (byteSize: size, inventory: old), preset: .balanced)], custom: spec,
                quickTimeFallbacks: [1]
            ).first)
        let settings = ConvertJobSettings(
            preset: .balanced, saveTo: .nextToOriginal, custom: spec, predictedLost: loss.lost,
            predictedLostKeys: loss.keys)

        let state = try await RunnerFixture.runner().run(try RunnerFixture.job(source, settings)) { _ in }

        guard case .completed(let outcome) = state else {
            Issue.record("expected completed, got \(state)")
            return
        }
        #expect(loss.lost.contains("Location"))
        #expect(outcome.isVerified)
    }

    /// The add-time probe missed the fallback (or the job predates the prediction): what QuickTime loses was never
    /// shown, so the copy is not made. That is known before encoding, so nothing is encoded.
    @Test(.timeLimit(.minutes(5)), arguments: [[String]?.some([]), nil])
    func fallbackFoundOnlyAtRunTimeKeepsTheOriginalAsIs(_ predictedLost: [String]?) async throws {
        let source = try await RunnerFixture.source(
            name: "x.m4v", fileType: .mp4, timedMetadata: true, metadata: RunnerFixture.locationMetadata)
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = ConvertJobSettings(
            preset: .balanced, saveTo: .nextToOriginal, custom: spec, predictedLost: predictedLost)
        let progressReported = Mutex(false)

        let state = try await RunnerFixture.runner().run(try RunnerFixture.job(source, settings)) { _ in
            progressReported.withLock { $0 = true }
        }

        #expect(
            state == .keptAsIs(reason: "Its file format can't keep all of its details", code: .formatCannotKeepDetails))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [source.lastPathComponent])
        #expect(!progressReported.withLock { $0 })
    }

    /// An already-small MPEG-4 clip with ISO user data is kept for being small, not for its file format: the
    /// planner speaks first.
    @Test(.timeLimit(.minutes(5))) func alreadySmallMPEG4WithIsoUserDataKeepsTheSmallReason() async throws {
        let source = try await RunnerFixture.smallSource(
            name: "small.m4v", fileType: .mp4, timedMetadata: true, metadata: RunnerFixture.locationMetadata)
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = ConvertJobSettings(
            preset: .balanced, saveTo: .nextToOriginal, custom: spec, predictedLost: [], predictedLostKeys: [])

        let state = try await RunnerFixture.runner().run(try RunnerFixture.job(source, settings)) { _ in }

        #expect(state == .keptAsIs(reason: "Already small", code: .alreadySmall))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [source.lastPathComponent])
    }

    @Test func fallbackLossCountsAsShownOnlyWhenEveryItemWasPredicted() {
        let inventory = MetadataInventory(items: [
            MetadataItem(key: "qt.uiso/loci", category: .location, displayName: "Location", value: "+1+2/"),
            MetadataItem(key: "qt.uiso/date", category: .date, displayName: "Creation date", value: "2026"),
        ])
        func shown(_ names: [String]?, keys: [String]? = nil) -> Bool {
            ConvertRunner.fallbackLossWasShown(inventory, predictedLost: names, predictedLostKeys: keys)
        }
        // Keys, when the job recorded them, decide.
        #expect(shown(nil, keys: ["qt.uiso/date", "qt.uiso/loci", "x"]))
        #expect(!shown(["Location", "Creation date"], keys: ["qt.uiso/loci"]))
        // Jobs saved before keys were recorded: by name, plain or the four-character code older sheets showed.
        #expect(shown(["Creation date", "Location", "x"]))
        #expect(shown(["loci", "date"]))
        #expect(!shown(["Location"]))
        #expect(!shown([]))
        #expect(!shown(nil))
        // Nothing to lose: nothing to have been shown.
        #expect(
            ConvertRunner.fallbackLossWasShown(
                MetadataInventory(items: []), predictedLost: nil, predictedLostKeys: nil))
    }

    @Test(.timeLimit(.minutes(5)), arguments: [SaveDestination.nextToOriginal, .replace])
    func unpredictedLossInAnotherContainerKeepsTheOriginalAsIs(_ destination: SaveDestination) async throws {
        let source = try await RunnerFixture.source(name: "x.m4v", fileType: .mp4, timedMetadata: true)
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        // The QuickTime output turns out to lack something nobody predicted.
        let runner = ConvertRunner(
            trash: { _ in throw CocoaError(.fileWriteNoPermission) },
            inspect: { url in
                var inventory = try await MediaInspector().inventory(of: url)
                let audioKeys = Set(inventory.items.map(\.key).filter { $0.hasPrefix("audio.") })
                guard !audioKeys.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                inventory.items.removeAll { audioKeys.contains($0.key) }
                return inventory
            },
            diskSpace: RunnerFixture.roomy)
        let settings = ConvertJobSettings(preset: .balanced, saveTo: destination, custom: spec)

        let state = try await runner.run(try RunnerFixture.job(source, settings)) { _ in }

        #expect(
            state == .keptAsIs(reason: "Its file format can't keep all of its details", code: .formatCannotKeepDetails))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [source.lastPathComponent])
    }

    @Test(.timeLimit(.minutes(5))) func replaceUnderATakenNameSaysWhy() async throws {
        let source = try await RunnerFixture.source(name: "x.m4v", fileType: .mp4, timedMetadata: true)
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let taken = directory.appending(path: "x.mov")
        try Data("someone else's file".utf8).write(to: taken)
        let runner = ConvertRunner(
            trash: { url in
                let trashed = directory.appending(path: "trashed-\(UUID().uuidString)")
                try FileManager.default.moveItem(at: url, to: trashed)
                return trashed
            },
            diskSpace: RunnerFixture.roomy)
        let settings = ConvertJobSettings(preset: .balanced, saveTo: .replace, custom: spec)

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

    @Test(.timeLimit(.minutes(5))) func sameContainerRunHasNoNotes() async throws {
        let source = try await RunnerFixture.source()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let settings = ConvertJobSettings(preset: .balanced, saveTo: .nextToOriginal, custom: spec)

        let state = try await RunnerFixture.runner().run(try RunnerFixture.job(source, settings)) { _ in }

        guard case .completed(let outcome) = state else {
            Issue.record("expected completed, got \(state)")
            return
        }
        #expect(outcome.notes.isEmpty)
    }

    // MARK: - Our output never outlives a failed check

    @Test(.timeLimit(.minutes(5))) func failingToInspectTheOutputRemovesIt() async throws {
        let source = try await RunnerFixture.source()
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = ConvertRunner(
            trash: { _ in throw CocoaError(.fileWriteNoPermission) },
            inspect: { _ in throw CocoaError(.fileReadCorruptFile) },
            diskSpace: RunnerFixture.roomy)
        let settings = ConvertJobSettings(preset: .balanced, saveTo: .nextToOriginal, custom: spec)

        await #expect(throws: CocoaError.self) {
            _ = try await runner.run(try RunnerFixture.job(source, settings)) { _ in }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [source.lastPathComponent])
    }

    @Test(.timeLimit(.minutes(5))) func failingToMeasureTheOutputRemovesIt() async throws {
        let source = try await RunnerFixture.source()
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = ConvertRunner(
            trash: { _ in throw CocoaError(.fileWriteNoPermission) },
            sizeOf: { _ in throw CocoaError(.fileReadUnknown) },
            diskSpace: RunnerFixture.roomy)
        let settings = ConvertJobSettings(preset: .balanced, saveTo: .nextToOriginal, custom: spec)

        await #expect(throws: CocoaError.self) {
            _ = try await runner.run(try RunnerFixture.job(source, settings)) { _ in }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [source.lastPathComponent])
    }

    @Test(.timeLimit(.minutes(5))) func cancelledWhileInspectingTheOutputRemovesIt() async throws {
        let source = try await RunnerFixture.source()
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = ConvertRunner(
            trash: { _ in throw CocoaError(.fileWriteNoPermission) },
            inspect: { _ in throw CancellationError() },
            diskSpace: RunnerFixture.roomy)
        let settings = ConvertJobSettings(preset: .balanced, saveTo: .nextToOriginal, custom: spec)

        await #expect(throws: CancellationError.self) {
            _ = try await runner.run(try RunnerFixture.job(source, settings)) { _ in }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [source.lastPathComponent])
    }

    // MARK: - The file the run used

    @Test(.timeLimit(.minutes(5))) func outcomeRecordsTheFileTheRunActuallyRead() async throws {
        let original = try await RunnerFixture.source()
        let directory = original.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bookmark = try original.bookmarkData()
        // The file moved after it was added; its bookmark still finds it.
        let moved = directory.appending(path: "moved.mov")
        try FileManager.default.moveItem(at: original, to: moved)
        let settings = ConvertJobSettings(preset: .balanced, saveTo: .nextToOriginal, custom: spec)
        let job = Job(
            toolID: ConvertTool.toolID, source: original, sourceBookmark: bookmark,
            settings: try JSONEncoder().encode(settings))

        let state = try await RunnerFixture.runner().run(job) { _ in }

        guard case .completed(let outcome) = state else {
            Issue.record("expected completed, got \(state)")
            return
        }
        #expect(outcome.source?.standardizedFileURL.resolvingSymlinksInPath() == moved.resolvingSymlinksInPath())
    }
}
