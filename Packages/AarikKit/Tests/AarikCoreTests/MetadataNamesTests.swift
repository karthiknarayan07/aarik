import Testing

@testable import AarikCore

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

@Test func timedMetadataTracksGetPlainNames() {
    let illuminance = "timed.mdta/com.apple.quicktime.scene-illuminance"
    #expect(MetadataNames.plainName(of: item(illuminance, "present")) == "Scene brightness data")
    #expect(MetadataNames.plainName(of: item(illuminance + ".duration", "15398")) == "Scene brightness data duration")
    #expect(MetadataNames.plainName(of: item("timed.mdta/com.example.unknown", "present")) == "Camera data track")
    #expect(
        MetadataNames.plainName(of: item("timed.mdta/com.example.unknown.duration", "1"))
            == "Camera data track duration")
}

@Test func durationsAreShownInSeconds() {
    #expect(MetadataNames.plainName(key: "video.duration", displayName: "Duration (ms)") == "Duration")
    #expect(
        MetadataNames.plainName(key: "audio.0.duration", displayName: "Audio track 1 duration (ms)")
            == "Audio track 1 duration")
    #expect(
        MetadataNames.plainValue(key: "timed.mdta/com.apple.quicktime.scene-illuminance.duration", value: "15398")
            == "15.398 s")
    #expect(MetadataNames.plainValue(key: "video.duration", value: "unknown") == "unknown")
    #expect(MetadataNames.plainValue(key: "video.dimensions", value: "3840x2160") == "3840x2160")
}

@Test func aChangeReadsAsOnePlainSentence() {
    let change = MetadataChange(
        key: "timed.mdta/com.apple.quicktime.scene-illuminance.duration",
        displayName: "Timed metadata mdta/com.apple.quicktime.scene-illuminance duration", from: "15398", to: "15397")
    #expect(
        MetadataNames.changeSentence(change) == "Scene brightness data duration changed from 15.398 s to 15.397 s")
}
