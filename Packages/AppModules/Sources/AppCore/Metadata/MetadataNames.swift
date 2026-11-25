/// Plain names for metadata items, decided by key so that inventories read at different times (with older display
/// names) are named alike. The one place lost and changed items get their user-facing names.
public enum MetadataNames {
    /// An auxiliary video track (Cinematic disparity) and its track metadata, as one entry.
    public static let cinematicDepth = "Cinematic depth data"

    /// The ISO user data an MPEG-4 writer makes of QuickTime items (`qt.uiso/<code>`), by four-character code.
    public static let isoUserData: [String: (name: String, category: MetadataCategory)] = [
        "loci": ("Location", .location),
        "date": ("Creation date", .date),
        "titl": ("Title", .other),
        "auth": ("Author", .other),
        "dscp": ("Description", .other),
        "cprt": ("Copyright", .other),
        "perf": ("Performer", .other),
        "gnre": ("Genre", .other),
        "yrrc": ("Year", .other),
        "albm": ("Album", .other),
        "kywd": ("Keywords", .other),
    ]

    static let isoUserDataPrefix = "qt.uiso/"

    /// The four-character code of a `qt.uiso/<code>` key; nil for other keys.
    public static func isoUserDataCode(forKey key: String) -> String? {
        key.hasPrefix(isoUserDataPrefix) ? String(key.dropFirst(isoUserDataPrefix.count)) : nil
    }

    /// The name of a known `qt.uiso/<code>` key; nil for an unknown code or another key.
    public static func isoUserDataName(forKey key: String) -> String? {
        isoUserDataCode(forKey: key).flatMap { isoUserData[$0]?.name }
    }

    /// The indexes of auxiliary video tracks (`track.<n>.kind` = `auxv/…`) among `items`.
    public static func auxiliaryTracks(in items: [MetadataItem]) -> Set<Int> {
        Set(
            items.compactMap { item in
                let parts = item.key.split(separator: ".")
                guard parts.count == 3, parts[0] == "track", parts[2] == "kind", item.value.hasPrefix("auxv/") else {
                    return nil
                }
                return Int(parts[1])
            })
    }

    /// The plain name of one item. `auxiliaryTracks` (from `auxiliaryTracks(in:)`) says which tracks' metadata is
    /// Cinematic depth data.
    public static func plainName(of item: MetadataItem, auxiliaryTracks: Set<Int> = []) -> String {
        let auxiliary = auxiliaryTracks.union(Self.auxiliaryTracks(in: [item]))
        return plainName(key: item.key, displayName: item.displayName, auxiliaryTracks: auxiliary)
    }

    /// `plainName(of:auxiliaryTracks:)` for a change, which has a key and a display name but no value.
    public static func plainName(key: String, displayName: String, auxiliaryTracks: Set<Int> = []) -> String {
        if let name = isoUserDataName(forKey: key) { return name }
        if key.hasPrefix(timedPrefix) {
            let identifier = key.dropFirst(timedPrefix.count)
            if identifier.hasSuffix(durationSuffix) {
                return timedMetadataName(String(identifier.dropLast(durationSuffix.count))) + " duration"
            }
            return timedMetadataName(String(identifier))
        }
        if let track = trackIndex(ofKey: key, prefix: "track."), key.hasSuffix(".kind"),
            auxiliaryTracks.contains(track)
        {
            return cinematicDepth
        }
        if let track = trackIndex(ofKey: key, prefix: "trackmeta."), auxiliaryTracks.contains(track) {
            return cinematicDepth
        }
        // Durations are shown in seconds (`plainValue`), so their names drop the unit.
        if key.hasSuffix(durationSuffix), displayName.hasSuffix(" (ms)") {
            return String(displayName.dropLast(" (ms)".count))
        }
        return displayName
    }

    /// Timed metadata tracks by identifier (`<key space>/<key>`); any other is a camera data track.
    public static let timedMetadata: [String: String] = [
        "mdta/com.apple.quicktime.scene-illuminance": "Scene brightness data",
        "mdta/com.apple.quicktime.video-orientation": "Orientation data",
        "mdta/com.apple.quicktime.detected-face": "Face detection data",
        "mdta/com.apple.quicktime.live-photo-info": "Live Photo data",
        "mdta/com.apple.quicktime.still-image-time": "Live Photo still frame time",
        "mdta/com.apple.quicktime.location.ISO6709": "Location track",
    ]

    /// The plain name of a timed metadata track (`timed.<identifier>`).
    public static func timedMetadataName(_ identifier: String) -> String {
        timedMetadata[identifier] ?? "Camera data track"
    }

    /// A value as shown: a duration in whole milliseconds as seconds ("15.398 s"); anything else as it is.
    public static func plainValue(key: String, value: String) -> String {
        guard key.hasSuffix(durationSuffix), let milliseconds = Int(value) else { return value }
        return String(format: "%.3f s", Double(milliseconds) / 1000)
    }

    /// "<name> changed from <value> to <value>", in plain names and values.
    public static func changeSentence(_ change: MetadataChange, auxiliaryTracks: Set<Int> = []) -> String {
        let name = plainName(key: change.key, displayName: change.displayName, auxiliaryTracks: auxiliaryTracks)
        let from = plainValue(key: change.key, value: change.from)
        let to = plainValue(key: change.key, value: change.to)
        return "\(name) changed from \(from) to \(to)"
    }

    static let timedPrefix = "timed."
    static let durationSuffix = ".duration"

    /// Plain names for `items`, each once, in order. `context` (for example the whole source inventory) helps
    /// tell which tracks are auxiliary when `items` lacks their `track.<n>.kind`.
    public static func plainNames(of items: [MetadataItem], context: [MetadataItem] = []) -> [String] {
        let auxiliary = auxiliaryTracks(in: items + context)
        var seen = Set<String>()
        return items.map { plainName(of: $0, auxiliaryTracks: auxiliary) }.filter { seen.insert($0).inserted }
    }

    /// `<n>` of `<prefix><n>.…`.
    private static func trackIndex(ofKey key: String, prefix: String) -> Int? {
        guard key.hasPrefix(prefix) else { return nil }
        return key.dropFirst(prefix.count).split(separator: ".").first.flatMap { Int($0) }
    }
}
