import Testing

@testable import AppCore

private func item(_ key: String, _ value: String = "1", name: String? = nil) -> MetadataItem {
    MetadataItem(key: key, category: .other, displayName: name ?? key, value: value)
}

@Test func isoUserDataIsNamedByItsKeyWhateverItsStoredName() {
    // Inventories read before ISO user data had names call it by its four-character code.
    #expect(MetadataNames.plainName(of: item("qt.uiso/loci", name: "loci")) == "Location")
    #expect(MetadataNames.plainName(of: item("qt.uiso/loci", name: "Location")) == "Location")
    #expect(MetadataNames.plainName(of: item("qt.uiso/date", name: "date")) == "Creation date")
    #expect(MetadataNames.isoUserDataName(forKey: "qt.uiso/kywd") == "Keywords")
    #expect(MetadataNames.isoUserDataName(forKey: "qt.uiso/zzzz") == nil)
    #expect(MetadataNames.isoUserDataName(forKey: "qt.com.apple.quicktime.make") == nil)
    // Unknown codes keep their stored name.
    #expect(MetadataNames.plainName(of: item("qt.uiso/zzzz", name: "zzzz")) == "zzzz")
}

@Test func anAuxiliaryVideoTrackAndItsTrackMetadataAreOneCinematicLine() {
    let items = [
        item("qt.uiso/loci", name: "loci"),
        item("track.1.kind", "auxv/dish", name: "Track 2 kind"),
        item("trackmeta.1.tagc", name: "Track 2 tagc"),
        item("trackmeta.1.com.apple.quicktime.x", name: "Track 2 x"),
        item("trackmeta.3.tagc", name: "Track 4 tagc"),
    ]

    #expect(MetadataNames.plainNames(of: items) == ["Location", "Cinematic depth data", "Track 4 tagc"])
}

@Test func trackMetadataOfAnAuxiliaryTrackKnownFromContextIsCinematic() {
    let context = [item("track.1.kind", "auxv/dish")]
    #expect(
        MetadataNames.plainNames(of: [item("trackmeta.1.tagc", name: "Track 2 tagc")], context: context) == [
            "Cinematic depth data"
        ])
}
