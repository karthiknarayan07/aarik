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
        case .edited: "Edited"
        case .sdr: "SDR"
        }
    }

    /// The short label on a tile.
    public var tileLabel: String { self == .dolbyVision ? "DV" : displayName }

    public var systemImage: String {
        switch self {
        case .dolbyVision: "sun.max.circle"
        case .hdr: "sun.max"
        case .k4: "4k.tv"
        case .cinematic: "camera.aperture"
        case .sloMo: "slowmo"
        case .spatial: "visionpro"
        case .edited: "slider.horizontal.3"
        case .sdr: "tv"
        }
    }

    /// Badges in display order.
    public static func ordered(_ badges: Set<MediaBadge>) -> [MediaBadge] {
        allCases.filter(badges.contains)
    }
}
