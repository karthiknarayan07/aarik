#if DEBUG
    import AVFoundation
    import AppCore
    import CoreLocation
    import Foundation
    import MediaEngine
    import Photos

    /// DEBUG-only PhotoKit spike (Plan 3, Task 1). Launch with `-photosSpike` (and optionally
    /// `-photosSpikeClip <path>` for the generated test clip) to run every step once and log each fact as a line
    /// in `~/Library/Logs/<bundle id>-photos-spike.log`. Deleted again in Plan 3, Task 8.
    ///
    /// It reads the real library (counts, flags, sizes) and writes only: one unedited and one edited clip's
    /// resources to the temp folder, and one generated test clip into Photos, which is deleted again together with
    /// its temporary album.
    enum PhotosSpike {
        static var isRequested: Bool { CommandLine.arguments.contains("-photosSpike") }

        static func start() {
            Task.detached { await SpikeRunner().run() }
        }
    }

    /// Runs the steps in order; a failing step is logged and the next one still runs.
    struct SpikeRunner {
        static let albumTitle = "Photos spike test"
        /// Clips read from the owner's library stay below this, so nothing large is ever pulled in.
        static let sizeLimit: Int64 = 100_000_000

        let log = SpikeLog()
        let tempFolder = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Movies/AppVisualTest/photos-spike", directoryHint: .isDirectory)

        func run() async {
            log.line("SPIKE start, macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
            try? FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
            guard await authorize() else {
                log.line("SPIKE done (no access)")
                return
            }
            var facts: [VideoFacts] = []
            do {
                log.line("STEP 1 survey")
                facts = try survey()
            } catch {
                log.line("STEP 1 failed: \(describe(error))")
            }
            // `-photosSpikeOnly <step number>` runs just that step (after the survey).
            let only = Self.argument("-photosSpikeOnly")
            func run(_ number: String, _ title: String, _ body: () async throws -> Void) async {
                guard only == nil || only == number else { return }
                await step("\(number) \(title)", body)
            }
            await run("2", "unedited .video resource") { try await uneditedResource(facts) }
            await run("3", "edited rendering") { try await editedRendering(facts) }
            await run("3b", "edited rendering, not on this Mac") { try await editedCloudRendering(facts) }
            await run("4", "save round trip") { try await saveRoundTrip() }
            log.line("SPIKE done")
        }

        static func argument(_ name: String) -> String? {
            let arguments = CommandLine.arguments
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }

        private func step(_ name: String, _ body: () async throws -> Void) async {
            log.line("STEP \(name)")
            do { try await body() } catch { log.line("STEP \(name) failed: \(describe(error))") }
        }

        private func authorize() async -> Bool {
            let before = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            log.line("AUTH before=\(before.rawValue) (0 undetermined, 2 denied, 3 authorized, 4 limited)")
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            log.line("AUTH after=\(status.rawValue)")
            return status == .authorized || status == .limited
        }

        // MARK: - Step 1: survey

        private func survey() throws -> [VideoFacts] {
            let started = Date()
            let options = PHFetchOptions()
            options.includeAssetSourceTypes = [.typeUserLibrary]
            let result = PHAsset.fetchAssets(with: .video, options: options)
            options.includeHiddenAssets = true
            let withHidden = PHAsset.fetchAssets(with: .video, options: options).count
            log.line("COUNT videos=\(result.count) (hidden excluded) withHidden=\(withHidden)")

            var facts: [VideoFacts] = []
            facts.reserveCapacity(result.count)
            var index = 0
            while index < result.count {
                let range = index..<min(index + 200, result.count)
                autoreleasepool {
                    for asset in result.objects(at: IndexSet(integersIn: range)) {
                        facts.append(VideoFacts(asset))
                    }
                }
                index = range.upperBound
            }
            log.line("TIMING enumerated \(facts.count) assets with resources in \(seconds(since: started))")
            SurveyReport(facts: facts, log: log).write()
            return facts
        }

        // MARK: - Step 2: unedited clip

        private func uneditedResource(_ facts: [VideoFacts]) async throws {
            let candidates =
                facts
                .filter { $0.isPlainCandidate }
                .sorted { ($0.videoSize ?? 0) > ($1.videoSize ?? 0) }
            log.line(
                "CANDIDATES unedited local clips under 100 MB, not cinematic/spatial/timelapse: \(candidates.count)")
            for (number, candidate) in candidates.prefix(8).enumerated() {
                guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [candidate.id], options: nil).firstObject,
                    let resource = PHAssetResource.assetResources(for: asset).first(where: { $0.type == .video })
                else { continue }
                let url = tempFolder.appending(path: "unedited-\(number).mov")
                let started = Date()
                try await write(resource, to: url)
                log.line(
                    "WRITE unedited .video candidate \(number): \(candidate.videoSize ?? 0) bytes in \(seconds(since: started)); "
                        + "asset has location=\(asset.location != nil) creationDate=\(asset.creationDate != nil)")
                let inventory = try await MediaInspector().inventory(of: url)
                log.inventory("INVENTORY unedited-\(number)", inventory)
                if inventory.items.contains(where: { $0.key == "hdr.dolbyVision" }) {
                    log.line(
                        "RESULT unedited DV clip found at candidate \(number); the file is the .video resource as stored"
                    )
                    log.line("RESULT unedited file size on disk=\(fileSize(url)) bytes")
                    return
                }
                try? FileManager.default.removeItem(at: url)
            }
            log.line("RESULT no unedited Dolby Vision clip found among the tried candidates")
        }

        // MARK: - Step 3: edited clip

        private func editedRendering(_ facts: [VideoFacts]) async throws {
            let candidates = facts.filter { $0.isEditedCandidate }
            let withRendering = candidates.filter { $0.fullSizeVideoLocal == true }
            log.line(
                "CANDIDATES edited local clips under 100 MB: \(candidates.count); with a local .fullSizeVideo resource: \(withRendering.count)"
            )
            guard let pick = withRendering.first ?? candidates.first,
                let asset = PHAsset.fetchAssets(withLocalIdentifiers: [pick.id], options: nil).firstObject
            else {
                log.line("RESULT no usable edited clip")
                return
            }
            let resources = PHAssetResource.assetResources(for: asset)
            log.line("EDITED resources: \(resources.map { resourceTypeName($0.type) }.joined(separator: ", "))")

            if let original = resources.first(where: { $0.type == .video }) {
                let url = tempFolder.appending(path: "edited-original.mov")
                try await write(original, to: url)
                log.inventory("INVENTORY edited-original (.video)", try await MediaInspector().inventory(of: url))
            }
            if let rendering = resources.first(where: { $0.type == .fullSizeVideo }) {
                let url = tempFolder.appending(path: "edited-fullsize.mov")
                let started = Date()
                try await write(rendering, to: url)
                log.line("WRITE edited .fullSizeVideo in \(seconds(since: started)), \(fileSize(url)) bytes")
                log.inventory("INVENTORY edited-fullSizeVideo", try await MediaInspector().inventory(of: url))
                await compare("edited .video -> .fullSizeVideo", tempFolder.appending(path: "edited-original.mov"), url)
            } else {
                log.line("RESULT edited clip has no .fullSizeVideo resource")
            }
            await exportSession(for: asset)
        }

        func exportSession(
            for asset: PHAsset, label: String = "edited", network: Bool = false, compareTo original: URL? = nil
        ) async {
            let options = PHVideoRequestOptions()
            options.version = .current
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = network
            let url = tempFolder.appending(path: "\(label)-export.mov")
            try? FileManager.default.removeItem(at: url)
            let started = Date()
            let session: AVAssetExportSession? = await withCheckedContinuation { continuation in
                PHImageManager.default().requestExportSession(
                    forVideo: asset, options: options, exportPreset: AVAssetExportPresetPassthrough
                ) { session, info in
                    if session == nil {
                        let inCloud = info?[PHImageResultIsInCloudKey]
                        let error = (info?[PHImageErrorKey] as? Error).map(describe)
                        self.log.line(
                            "EXPORT \(label) no session (network=\(network)): inCloud=\(String(describing: inCloud)) "
                                + "error=\(error ?? "none")")
                    }
                    nonisolated(unsafe) let session = session
                    continuation.resume(returning: session)
                }
            }
            guard let session else { return }
            do {
                try await session.export(to: url, as: .mov)
                log.line(
                    "EXPORT \(label) passthrough .mov (network=\(network)) done in \(seconds(since: started)), \(fileSize(url)) bytes"
                )
                log.inventory(
                    "INVENTORY \(label)-export (requestExportSession, current, passthrough)",
                    try await MediaInspector().inventory(of: url))
                await compare(
                    "\(label) .video -> export session", original ?? tempFolder.appending(path: "edited-original.mov"),
                    url)
            } catch {
                log.line("EXPORT failed: \(describe(error))")
            }
        }

        /// Logs which metadata survives from `source` to `output`.
        func compare(_ label: String, _ source: URL, _ output: URL) async {
            do {
                let before = try await MediaInspector().inventory(of: source)
                let after = try await MediaInspector().inventory(of: output)
                log.diff(label, MetadataDiff.report(source: before, output: after), source: before)
            } catch {
                log.line("DIFF \(label) failed: \(describe(error))")
            }
        }
    }
#endif
