extension MediaBadge {
    /// The name in the sidebar, the inspector and VoiceOver.
    public var displayName: String {
        switch self {
        case .dolbyVision: "Dolby Vision"
        case .hdr: "HDR"
        case .k4: "4K"
        case .cinematic: "Cinematic"
        case .sloMo: "Slo-mo"
        case .spatial: "Spatial"
        case .livePhoto: "Live Photo"
        case .portrait: "Portrait"
        case .raw: "RAW"
        case .animated: "Animated"
        case .transparent: "Transparent"
        case .edited: "Edited"
        case .sdr: "SDR"
        }
    }

    /// The short label on a tile.
    public var tileLabel: String {
        switch self {
        case .dolbyVision: "DV"
        case .livePhoto: "Live"
        case .transparent: "Alpha"
        default: displayName
        }
    }

    public var systemImage: String {
        switch self {
        case .dolbyVision: "sun.max.circle"
        case .hdr: "sun.max"
        case .k4: "4k.tv"
        case .cinematic: "camera.aperture"
        case .sloMo: "slowmo"
        case .spatial: "visionpro"
        case .livePhoto: "livephoto"
        case .portrait: "person.crop.rectangle"
        case .raw: "camera.metering.spot"
        case .animated: "square.stack.3d.down.right"
        case .transparent: "checkerboard.rectangle"
        case .edited: "slider.horizontal.3"
        case .sdr: "tv"
        }
    }

    /// Badges in display order.
    public static func ordered(_ badges: Set<MediaBadge>) -> [MediaBadge] {
        allCases.filter(badges.contains)
    }
}
