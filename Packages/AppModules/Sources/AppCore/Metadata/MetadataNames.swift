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
        if let track = trackIndex(ofKey: key, prefix: "track."), key.hasSuffix(".kind"),
            auxiliaryTracks.contains(track)
        {
            return cinematicDepth
        }
        if let track = trackIndex(ofKey: key, prefix: "trackmeta."), auxiliaryTracks.contains(track) {
            return cinematicDepth
        }
        return displayName
    }

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
