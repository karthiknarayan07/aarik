#if DEBUG
    import AppCore
    import Foundation
    import OSLog
    import Photos
    import Synchronization

    /// One line per fact, to the spike's log file and to `os.Logger`.
    final class SpikeLog: Sendable {
        private let file: Mutex<FileHandle?>
        private let logger = Logger(subsystem: "photos-spike", category: "spike")
        private let started = Date()

        init() {
            let bundleID = Bundle.main.bundleIdentifier ?? "app"
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Logs/\(bundleID)-photos-spike.log")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            file = Mutex(try? FileHandle(forWritingTo: url))
        }

        func line(_ text: String) {
            logger.notice("\(text, privacy: .public)")
            let stamp = String(format: "[%7.1fs] ", Date().timeIntervalSince(started))
            file.withLock { try? $0?.write(contentsOf: Data((stamp + text + "\n").utf8)) }
        }

        /// Technical items in full; location and date values are only reported as present.
        func inventory(_ label: String, _ inventory: MetadataInventory) {
            var parts: [String] = []
            for item in inventory.items {
                switch item.category {
                case .location, .date: parts.append("\(item.displayName)=present")
                case .fileSystem: continue
                default: parts.append("\(item.displayName)=\(item.value)")
                }
            }
            line("\(label): " + parts.joined(separator: "; "))
        }

        func diff(_ label: String, _ report: MetadataReport, source: MetadataInventory) {
            func shown(_ name: String, key: String, from: String, to: String) -> String {
                let category = source[key]?.category
                return category == .location || category == .date
                    ? "\(name) (value differs)" : "\(name): \(from) -> \(to)"
            }
            line("DIFF \(label): kept \(report.kept.count), changed \(report.changed.count), lost \(report.lost.count)")
            for item in report.kept where [.hdr, .camera, .location, .date].contains(item.category) {
                line("DIFF \(label) kept: \(item.displayName)")
            }
            for change in report.changed {
                line(
                    "DIFF \(label) changed: "
                        + shown(change.displayName, key: change.key, from: change.from, to: change.to))
            }
            for item in report.lost where item.category != .fileSystem {
                line("DIFF \(label) lost: \(item.displayName)")
            }
        }
    }

    /// What the survey keeps per video asset. Metadata only: reading it never downloads.
    struct VideoFacts: Sendable {
        let id: String
        let hasAdjustments: Bool
        let subtypes: PHAssetMediaSubtype
        let duration: TimeInterval
        let resourceTypes: [String]
        let videoSize: Int64?
        let videoLocal: Bool?
        let fullSizeSize: Int64?
        let fullSizeVideoLocal: Bool?

        init(_ asset: PHAsset) {
            id = asset.localIdentifier
            hasAdjustments = asset.hasAdjustments
            subtypes = asset.mediaSubtypes
            duration = asset.duration
            let resources = PHAssetResource.assetResources(for: asset)
            resourceTypes = resources.map { resourceTypeName($0.type) }
            let video = resources.first { $0.type == .video }
            let fullSize = resources.first { $0.type == .fullSizeVideo }
            videoSize = video.flatMap(resourceSize)
            videoLocal = video.flatMap(resourceIsLocal)
            fullSizeSize = fullSize.flatMap(resourceSize)
            fullSizeVideoLocal = fullSize.flatMap(resourceIsLocal)
        }

        var isSpecialFormat: Bool {
            !subtypes.isDisjoint(with: [.videoCinematic, .spatialMedia, .videoTimelapse, .videoStreamed])
        }

        /// Small, local, unedited and an ordinary format: safe to read and likely Dolby Vision on a recent iPhone.
        var isPlainCandidate: Bool {
            !hasAdjustments && !isSpecialFormat && videoLocal == true && duration >= 1
                && (videoSize ?? 0) > 1_000_000 && (videoSize ?? .max) < SpikeRunner.sizeLimit
        }

        /// An edit whose rendering is still in iCloud, with rendering and original both small enough to fetch.
        var isCloudEditedCandidate: Bool {
            hasAdjustments && fullSizeVideoLocal == false && (fullSizeSize ?? .max) < 60_000_000
                && (videoSize ?? .max) < 60_000_000 && !isSpecialFormat
        }

        var isEditedCandidate: Bool {
            hasAdjustments && videoLocal == true && (videoSize ?? .max) < SpikeRunner.sizeLimit
                && (fullSizeSize ?? 0) < SpikeRunner.sizeLimit
        }
    }

    /// The numbers the ADR quotes.
    struct SurveyReport {
        let facts: [VideoFacts]
        let log: SpikeLog

        func write() {
            let flags: [(String, PHAssetMediaSubtype)] = [
                ("videoHighFrameRate", .videoHighFrameRate), ("videoCinematic", .videoCinematic),
                ("spatialMedia", .spatialMedia), ("videoTimelapse", .videoTimelapse), ("videoStreamed", .videoStreamed),
            ]
            for (name, flag) in flags {
                log.line("SUBTYPE \(name)=\(facts.filter { $0.subtypes.contains(flag) }.count)")
            }
            log.line(
                "SUBTYPE none=\(facts.filter { $0.subtypes.isDisjoint(with: PHAssetMediaSubtype(flags.map(\.1))) }.count)"
            )
            let edited = facts.filter(\.hasAdjustments)
            log.line("ADJUSTED hasAdjustments=\(edited.count) of \(facts.count)")
            log.line(
                "ADJUSTED with .fullSizeVideo resource=\(edited.filter { $0.resourceTypes.contains("fullSizeVideo") }.count), "
                    + "with .fullSizeVideo local=\(edited.filter { $0.fullSizeVideoLocal == true }.count), "
                    + "with .adjustmentData=\(edited.filter { $0.resourceTypes.contains("adjustmentData") }.count)")
            var signatures: [String: Int] = [:]
            for fact in facts { signatures[fact.resourceTypes.joined(separator: "+"), default: 0] += 1 }
            for (signature, count) in signatures.sorted(by: { $0.value > $1.value }) {
                log.line("RESOURCES \(signature)=\(count)")
            }
            let local = facts.filter { $0.videoLocal == true }
            let cloud = facts.filter { $0.videoLocal == false }
            let unknown = facts.filter { $0.videoLocal == nil }
            log.line("LOCAL .video local=\(local.count) cloud-only=\(cloud.count) unknown=\(unknown.count)")
            log.line(
                "LOCAL unedited local=\(local.filter { !$0.hasAdjustments }.count) edited local=\(local.filter(\.hasAdjustments).count)"
            )
            let sizes = facts.compactMap(\.videoSize).sorted()
            log.line("SIZE .video known for \(sizes.count) of \(facts.count) assets")
            if !sizes.isEmpty {
                let total = sizes.reduce(0, +)
                log.line(
                    "SIZE total=\(megabytes(total)) min=\(megabytes(sizes[0])) median=\(megabytes(sizes[sizes.count / 2])) "
                        + "p90=\(megabytes(sizes[sizes.count * 9 / 10])) max=\(megabytes(sizes[sizes.count - 1]))")
                log.line(
                    "SIZE local total=\(megabytes(local.compactMap(\.videoSize).reduce(0, +))) "
                        + "cloud-only total=\(megabytes(cloud.compactMap(\.videoSize).reduce(0, +)))")
                log.line(
                    "SIZE under 100 MB: \(sizes.filter { $0 < SpikeRunner.sizeLimit }.count) of \(sizes.count); "
                        + "at least 1 GB: \(sizes.filter { $0 >= 1_000_000_000 }.count)")
            }
        }

        private func megabytes(_ bytes: Int64) -> String { "\(bytes / 1_000_000) MB" }
    }

    // MARK: - Resource helpers

    func resourceTypeName(_ type: PHAssetResourceType) -> String {
        switch type {
        case .photo: "photo"
        case .video: "video"
        case .audio: "audio"
        case .alternatePhoto: "alternatePhoto"
        case .fullSizePhoto: "fullSizePhoto"
        case .fullSizeVideo: "fullSizeVideo"
        case .adjustmentData: "adjustmentData"
        case .adjustmentBasePhoto: "adjustmentBasePhoto"
        case .pairedVideo: "pairedVideo"
        case .fullSizePairedVideo: "fullSizePairedVideo"
        case .adjustmentBasePairedVideo: "adjustmentBasePairedVideo"
        case .adjustmentBaseVideo: "adjustmentBaseVideo"
        case .photoProxy: "photoProxy"
        @unknown default: "type\(type.rawValue)"
        }
    }

    /// The public `dataSize` on macOS 27, else the `fileSize` key; nil when neither is there.
    func resourceSize(_ resource: PHAssetResource) -> Int64? {
        if #available(macOS 27, *) {
            if let size = resource.dataSize { return Int64(size) }
        }
        return (keyValue(resource, "fileSize") as? NSNumber)?.int64Value
    }

    func resourceIsLocal(_ resource: PHAssetResource) -> Bool? {
        (keyValue(resource, "locallyAvailable") as? NSNumber)?.boolValue
    }

    /// Reads a key that may not exist, without raising: the getter (`key` or `isKey`) is checked first.
    func keyValue(_ object: NSObject, _ key: String) -> Any? {
        let boolean = "is" + key.prefix(1).uppercased() + key.dropFirst()
        guard object.responds(to: NSSelectorFromString(key)) || object.responds(to: NSSelectorFromString(boolean))
        else { return nil }
        return object.value(forKey: key)
    }

    func write(_ resource: PHAssetResource, to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options)
    }

    func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
    }

    func seconds(since date: Date) -> String { String(format: "%.1fs", Date().timeIntervalSince(date)) }

    func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) code \(nsError.code): \(nsError.localizedDescription)"
    }
#endif
