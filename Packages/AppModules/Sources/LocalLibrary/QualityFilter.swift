import Foundation

// MARK: - Dimensions

/// A rounded frame rate. Thresholds absorb the NTSC rates (23.976, 29.97, 59.94) and small timing jitter.
public enum FrameRateTier: Int, Sendable, Hashable, CaseIterable {
    case under23
    case fps24
    case fps25
    case fps30
    case fps60
    case fps120Plus

    /// The tier for `fps`, or nil when the rate is unknown (zero or less).
    public init?(fps: Double) {
        guard fps > 0 else { return nil }
        switch fps {
        case 100...: self = .fps120Plus
        case 50...: self = .fps60
        case 28...: self = .fps30
        case 24.5...: self = .fps25
        case 23...: self = .fps24
        default: self = .under23
        }
    }

    /// The suffix after a resolution, for example "60" in "4K60".
    var suffix: String {
        switch self {
        case .under23: ", under 23 fps"
        case .fps24: "24"
        case .fps25: "25"
        case .fps30: "30"
        case .fps60: "60"
        case .fps120Plus: "120+"
        }
    }
}

/// Resolution and frame rate together, from the short side of the displayed size: 4K and 1080p are split by
/// frame rate, 720p and smaller are not. A 4K or 1080p clip whose frame rate is unknown is `unknown`.
public enum QualityBucket: Sendable, Hashable, Comparable {
    case uhd(FrameRateTier)
    case fullHD(FrameRateTier)
    case hd
    case other
    case unknown

    public init(item: LibraryItem) {
        let shortSide = min(item.pixelSize.width, item.pixelSize.height)
        guard shortSide > 0 else {
            self = .unknown
            return
        }
        let tier = FrameRateTier(fps: item.frameRate)
        switch shortSide {
        case 2160...: self = tier.map(QualityBucket.uhd) ?? .unknown
        case 1080...: self = tier.map(QualityBucket.fullHD) ?? .unknown
        case 720...: self = .hd
        default: self = .other
        }
    }

    /// "4K60", "1080p30", "720p", "Other", "Unknown".
    public var title: String {
        switch self {
        case .uhd(let tier): "4K" + tier.suffix
        case .fullHD(let tier): "1080p" + tier.suffix
        case .hd: "720p"
        case .other: "Other"
        case .unknown: "Unknown"
        }
    }

    /// Display order: higher resolution first, then higher frame rate; Other and Unknown last.
    private var order: Int {
        switch self {
        case .uhd(let tier): 100 - tier.rawValue
        case .fullHD(let tier): 200 - tier.rawValue
        case .hd: 300
        case .other: 400
        case .unknown: 500
        }
    }

    public static func < (lhs: QualityBucket, rhs: QualityBucket) -> Bool { lhs.order < rhs.order }
}

/// "Bigger than" thresholds in decimal units, as Finder shows file sizes.
public enum SizeThreshold: Int64, Sendable, Hashable, CaseIterable, Comparable {
    case over100MB = 100_000_000
    case over500MB = 500_000_000
    case over1GB = 1_000_000_000

    public var title: String {
        switch self {
        case .over100MB: "Over 100 MB"
        case .over500MB: "Over 500 MB"
        case .over1GB: "Over 1 GB"
        }
    }

    public static func < (lhs: SizeThreshold, rhs: SizeThreshold) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Duration ranges; each lower bound is inclusive.
public enum LengthRange: Int, Sendable, Hashable, CaseIterable, Comparable {
    case underThirtySeconds
    case upToTwoMinutes
    case upToTenMinutes
    case overTenMinutes
    case unknown

    public init(seconds: Double) {
        guard seconds.isFinite, seconds > 0 else {
            self = .unknown
            return
        }
        switch seconds {
        case ..<30: self = .underThirtySeconds
        case ..<120: self = .upToTwoMinutes
        case ..<600: self = .upToTenMinutes
        default: self = .overTenMinutes
        }
    }

    public var title: String {
        switch self {
        case .underThirtySeconds: "Under 30 seconds"
        case .upToTwoMinutes: "30 seconds to 2 minutes"
        case .upToTenMinutes: "2 to 10 minutes"
        case .overTenMinutes: "Over 10 minutes"
        case .unknown: "Unknown length"
        }
    }

    public static func < (lhs: LengthRange, rhs: LengthRange) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The video codec family, from the inventory's `video.codec` four-character code.
public enum CodecFamily: Int, Sendable, Hashable, CaseIterable, Comparable {
    case hevc
    case h264
    case proRes
    case other

    private static let hevcCodes: Set<String> = ["hvc1", "hev1", "dvh1", "dvhe"]
    private static let h264Codes: Set<String> = ["avc1", "avc2", "avc3", "avc4", "dva1", "dvav"]
    private static let proResCodes: Set<String> = ["apch", "apcn", "apcs", "apco", "ap4h", "ap4x", "aprh", "aprn"]

    public init(code: String?) {
        let code = code?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        if Self.hevcCodes.contains(code) {
            self = .hevc
        } else if Self.h264Codes.contains(code) {
            self = .h264
        } else if Self.proResCodes.contains(code) {
            self = .proRes
        } else {
            self = .other
        }
    }

    public init(item: LibraryItem) { self.init(code: item.inventory["video.codec"]?.value) }

    public var title: String {
        switch self {
        case .hevc: "HEVC"
        case .h264: "H.264"
        case .proRes: "ProRes"
        case .other: "Other"
        }
    }

    public static func < (lhs: CodecFamily, rhs: CodecFamily) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One dynamic range per item: Dolby Vision wins over HDR (a Dolby Vision clip also carries an HDR transfer).
public enum DynamicRange: Int, Sendable, Hashable, CaseIterable, Comparable {
    case dolbyVision
    case hdr
    case sdr

    public init(badges: Set<MediaBadge>) {
        if badges.contains(.dolbyVision) {
            self = .dolbyVision
        } else if badges.contains(.hdr) {
            self = .hdr
        } else {
            self = .sdr
        }
    }

    public var title: String {
        switch self {
        case .dolbyVision: "Dolby Vision"
        case .hdr: "HDR"
        case .sdr: "SDR"
        }
    }

    public static func < (lhs: DynamicRange, rhs: DynamicRange) -> Bool { lhs.rawValue < rhs.rawValue }
}

// MARK: - Filter

/// Quality filters for the grid. Within a dimension the choices are alternatives (OR); dimensions combine with
/// AND, and with the media-type filter and search. An empty dimension matches everything.
///
/// Reads only `LibraryItem` fields (size, frame rate, byte size, duration, badges, inventory), so it works for
/// any library that produces items.
public struct QualityFilter: Sendable, Hashable {
    public var qualities: Set<QualityBucket> = []
    public var minimumSize: SizeThreshold?
    public var lengths: Set<LengthRange> = []
    public var codecs: Set<CodecFamily> = []
    public var ranges: Set<DynamicRange> = []

    public init(
        qualities: Set<QualityBucket> = [], minimumSize: SizeThreshold? = nil, lengths: Set<LengthRange> = [],
        codecs: Set<CodecFamily> = [], ranges: Set<DynamicRange> = []
    ) {
        self.qualities = qualities
        self.minimumSize = minimumSize
        self.lengths = lengths
        self.codecs = codecs
        self.ranges = ranges
    }

    public var isActive: Bool {
        !qualities.isEmpty || minimumSize != nil || !lengths.isEmpty || !codecs.isEmpty || !ranges.isEmpty
    }

    /// How many dimensions are narrowed.
    public var activeCount: Int {
        [!qualities.isEmpty, minimumSize != nil, !lengths.isEmpty, !codecs.isEmpty, !ranges.isEmpty]
            .filter { $0 }.count
    }

    public func matches(_ item: LibraryItem) -> Bool {
        Match(filter: self, traits: Traits(item)).all
    }

    /// The items that match, in their order, and the option counts for the filter bar.
    public func apply(to items: [LibraryItem]) -> (kept: [LibraryItem], facets: QualityFacets) {
        var kept: [LibraryItem] = []
        var counts = FacetCounts()
        for item in items {
            let traits = Traits(item)
            let match = Match(filter: self, traits: traits)
            if match.all { kept.append(item) }
            counts.add(traits, match)
        }
        return (kept, counts.facets)
    }

    /// An item's value in each dimension, computed once per pass.
    private struct Traits {
        let quality: QualityBucket
        let byteSize: Int64
        let length: LengthRange
        let codec: CodecFamily
        let range: DynamicRange

        init(_ item: LibraryItem) {
            quality = QualityBucket(item: item)
            byteSize = item.byteSize
            length = LengthRange(seconds: item.duration)
            codec = CodecFamily(item: item)
            range = DynamicRange(badges: item.badges)
        }
    }

    /// Whether an item passes each dimension on its own.
    private struct Match {
        let quality: Bool
        let size: Bool
        let length: Bool
        let codec: Bool
        let range: Bool

        init(filter: QualityFilter, traits: Traits) {
            quality = filter.qualities.isEmpty || filter.qualities.contains(traits.quality)
            size = filter.minimumSize.map { traits.byteSize > $0.rawValue } ?? true
            length = filter.lengths.isEmpty || filter.lengths.contains(traits.length)
            codec = filter.codecs.isEmpty || filter.codecs.contains(traits.codec)
            range = filter.ranges.isEmpty || filter.ranges.contains(traits.range)
        }

        var all: Bool { quality && size && length && codec && range }
    }

    /// Faceted counts: each dimension counts the items that pass every other dimension, so an option's count is
    /// what the grid would show if that option were the only choice in its dimension.
    private struct FacetCounts {
        var qualities: [QualityBucket: Tally] = [:]
        var sizes: [SizeThreshold: Tally] = [:]
        var lengths: [LengthRange: Tally] = [:]
        var codecs: [CodecFamily: Tally] = [:]
        var ranges: [DynamicRange: Tally] = [:]

        mutating func add(_ traits: Traits, _ match: Match) {
            if match.size && match.length && match.codec && match.range {
                qualities[traits.quality, default: .zero].add(traits.byteSize)
            }
            if match.quality && match.length && match.codec && match.range {
                for threshold in SizeThreshold.allCases where traits.byteSize > threshold.rawValue {
                    sizes[threshold, default: .zero].add(traits.byteSize)
                }
            }
            if match.quality && match.size && match.codec && match.range {
                lengths[traits.length, default: .zero].add(traits.byteSize)
            }
            if match.quality && match.size && match.length && match.range {
                codecs[traits.codec, default: .zero].add(traits.byteSize)
            }
            if match.quality && match.size && match.length && match.codec {
                ranges[traits.range, default: .zero].add(traits.byteSize)
            }
        }

        var facets: QualityFacets {
            QualityFacets(
                qualities: Self.options(qualities), sizes: Self.options(sizes), lengths: Self.options(lengths),
                codecs: Self.options(codecs), ranges: Self.options(ranges))
        }

        private static func options<Value: Comparable>(_ counts: [Value: Tally]) -> [QualityFacets.Option<Value>] {
            counts.map { QualityFacets.Option(value: $0.key, count: $0.value.count, bytes: $0.value.bytes) }
                .sorted { $0.value < $1.value }
        }
    }

    private struct Tally {
        var count = 0
        var bytes: Int64 = 0

        static let zero = Tally()

        mutating func add(_ byteSize: Int64) {
            count += 1
            bytes += byteSize
        }
    }
}

/// The options present in a collection, in display order, with how many items each would show and their total
/// size. Options with no items are absent.
public struct QualityFacets: Sendable, Equatable {
    public struct Option<Value: Hashable & Sendable>: Sendable, Hashable {
        public let value: Value
        public let count: Int
        /// The items' total size in bytes.
        public let bytes: Int64

        public init(value: Value, count: Int, bytes: Int64) {
            self.value = value
            self.count = count
            self.bytes = bytes
        }
    }

    public var qualities: [Option<QualityBucket>] = []
    public var sizes: [Option<SizeThreshold>] = []
    public var lengths: [Option<LengthRange>] = []
    public var codecs: [Option<CodecFamily>] = []
    public var ranges: [Option<DynamicRange>] = []

    public static let empty = QualityFacets()
}
