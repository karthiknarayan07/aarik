import AppCore
import Foundation
import LocalLibrary
import MediaEngine

/// What the Overview page shows: totals and "could free about" for Photos videos and for Local Files at the current
/// preset, the videos that would free the most, and what finished conversions have saved so far.
public struct OverviewSummary: Sendable, Equatable {
    public enum Library: Sendable, Equatable {
        case photos
        case localFiles
    }

    /// One library's videos.
    public struct Totals: Sendable, Equatable {
        public var count = 0
        public var bytes: Int64 = 0
        /// What converting the available ones would free; videos kept as is count as zero.
        public var couldFree: Int64 = 0

        public init(count: Int = 0, bytes: Int64 = 0, couldFree: Int64 = 0) {
            self.count = count
            self.bytes = bytes
            self.couldFree = couldFree
        }
    }

    /// A video that would free a lot.
    public struct Entry: Sendable, Equatable, Identifiable {
        /// The grid item's id.
        public let id: UUID
        public let library: Library
        public let name: String
        public let bytes: Int64
        public let couldFree: Int64
    }

    public static let biggestCount = 10

    public let videos: Totals
    public let localFiles: Totals
    /// Up to `biggestCount` videos from both libraries, the biggest saving first.
    public let biggest: [Entry]
    /// Bytes freed by finished conversions.
    public let savedBytes: Int64

    public var totalCouldFree: Int64 { videos.couldFree + localFiles.couldFree }

    /// What converting each available video would free, by item id: reading a video's metadata to estimate it is
    /// the costly part, so a refresh makes this once and hands it to everything that needs the numbers
    /// (`init`, `SavingsAnalyzer`). A video kept as is maps to 0.
    public static func estimates(
        photos: [LibraryItem], files: [LibraryItem], preset: Preset, overrides: PresetOverrides<UUID> = .init(),
        custom: DownscaleSpec? = nil, imageSpec: ImageSpec = ImageSpec()
    ) -> [UUID: Int64] {
        var result: [UUID: Int64] = [:]
        for item in photos + files where item.isAvailable {
            result[item.id] = couldFree(
                item, preset: overrides.preset(for: item.id, default: preset), custom: custom, imageSpec: imageSpec)
        }
        return result
    }

    /// `overrides` holds the presets chosen for single videos over `preset`; `custom`, when set, wins for all.
    /// `completed` are the outcomes of finished jobs. `estimates` (from `estimates(...)`) saves estimating again.
    public init(
        photos: [LibraryItem], files: [LibraryItem], preset: Preset, overrides: PresetOverrides<UUID> = .init(),
        custom: DownscaleSpec? = nil, completed: [JobOutcome] = [], estimates: [UUID: Int64]? = nil,
        imageSpec: ImageSpec = ImageSpec()
    ) {
        var videos = Totals()
        var localFiles = Totals()
        var entries: [Entry] = []
        for (library, items) in [(Library.photos, photos), (Library.localFiles, files)] {
            var totals = Totals()
            for item in items {
                totals.count += 1
                totals.bytes += item.byteSize
                guard item.isAvailable else { continue }
                let free =
                    estimates?[item.id]
                    ?? Self.couldFree(
                        item, preset: overrides.preset(for: item.id, default: preset), custom: custom,
                        imageSpec: imageSpec)
                totals.couldFree += free
                if free > 0 {
                    entries.append(
                        Entry(id: item.id, library: library, name: item.name, bytes: item.byteSize, couldFree: free))
                }
            }
            if library == .photos { videos = totals } else { localFiles = totals }
        }
        self.videos = videos
        self.localFiles = localFiles
        // Equal savings keep their library order (a stable sort), so the list doesn't shuffle between refreshes.
        self.biggest = Array(
            entries.enumerated().sorted { ($0.element.couldFree, $1.offset) > ($1.element.couldFree, $0.offset) }
                .prefix(Self.biggestCount).map(\.element))
        self.savedBytes = completed.reduce(0) { $0 + $1.savedBytes }
    }

    /// What converting one video or image would free at `preset` / `imageSpec`.
    static func couldFree(
        _ item: LibraryItem, preset: Preset, custom: DownscaleSpec?, imageSpec: ImageSpec = ImageSpec()
    ) -> Int64 {
        if item.isImage {
            guard item.pixelSize.width > 0, item.pixelSize.height > 0,
                case .convert(_, _, _, let estimate, _) = ImagePlanner.decide(
                    byteSize: item.byteSize, pixelSize: item.pixelSize, sourceUTI: item.imageSourceUTI,
                    inventory: item.inventory, spec: imageSpec, isLivePhoto: item.badges.contains(.livePhoto))
            else { return 0 }
            return max(0, item.byteSize - estimate)
        }
        let source = estimationSource(for: item)
        guard
            case .convert(_, let estimate, _) = SavingsCalculator.decision(
                byteSize: source.byteSize, inventory: source.inventory, preset: preset, custom: custom)
        else { return 0 }
        return max(0, source.byteSize - estimate)
    }

    /// The size and inventory the estimate reads. A file's inventory is complete. A Photos video has only what
    /// Photos says (size, length, frame rate, spatial), so the keys the planner needs are made from those.
    static func estimationSource(for item: LibraryItem) -> SavingsCalculator.Source {
        guard item.photosIdentifier != nil else { return (item.byteSize, item.inventory) }
        var inventory = item.inventory
        func add(_ key: String, _ category: MetadataCategory, _ value: String) {
            guard inventory[key] == nil else { return }
            inventory.items.append(MetadataItem(key: key, category: category, displayName: key, value: value))
        }
        add("video.dimensions", .video, "\(Int(item.pixelSize.width))x\(Int(item.pixelSize.height))")
        add("video.duration", .video, String(item.duration * 1000))
        if item.frameRate > 0 { add("video.frameRate", .video, String(item.frameRate)) }
        // The planner keeps spatial video as it is.
        if item.badges.contains(.spatial) { add("hdr.stereo", .hdr, "true") }
        return (item.byteSize, inventory)
    }
}
