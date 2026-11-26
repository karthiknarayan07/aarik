import AarikCore
import Testing

@testable import SharedUI

private func item(_ key: String, _ value: String = "1", name: String) -> MetadataItem {
    MetadataItem(key: key, category: .other, displayName: name, value: value)
}

@Test func summaryListsACinematicTrackAsOneLostLine() {
    let report = MetadataReport(
        kept: [item("video.dimensions", "3840x2160", name: "Dimensions")],
        lost: [
            item("track.1.kind", "auxv/dish", name: "Track 2 kind"),
            item("trackmeta.1.tagc", name: "Track 2 tagc"),
            item("trackmeta.1.com.apple.quicktime.x", name: "Track 2 x"),
        ])

    #expect(MetadataSummaryLines.lost(in: report) == ["Cinematic depth data"])
}

@Test func summaryShowsTimedMetadataPlainlyWithDurationsInSeconds() {
    let change = MetadataChange(
        key: "timed.mdta/com.apple.quicktime.scene-illuminance.duration",
        displayName: "Timed metadata mdta/com.apple.quicktime.scene-illuminance duration", from: "15398", to: "15397")

    let line = MetadataSummaryLines.change(change, in: MetadataReport(changed: [change]))

    #expect(line.name == "Scene brightness data duration")
    #expect(line.from == "15.398 s")
    #expect(line.to == "15.397 s")
}
