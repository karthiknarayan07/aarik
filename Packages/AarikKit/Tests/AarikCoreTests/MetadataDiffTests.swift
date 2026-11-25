import Testing

@testable import AarikCore

private func item(
    _ key: String, _ value: String, _ category: MetadataCategory = .other
) -> MetadataItem {
    MetadataItem(key: key, category: category, displayName: key, value: value)
}

@Test func identicalInventoriesAreLossless() {
    let items = [
        item("qt.com.apple.quicktime.make", "Apple", .camera),
        item("video.dimensions", "3840x2160", .video),
        item("audio.0.format", "aac ", .audio),
    ]
    let report = MetadataDiff.report(
        source: MetadataInventory(items: items),
        output: MetadataInventory(items: items)
    )
    #expect(report.kept.count == 3)
    #expect(report.changed.isEmpty)
    #expect(report.lost.isEmpty)
    #expect(report.isLossless)
}

@Test func missingKeyIsLost() {
    let location = item("qt.com.apple.quicktime.location.ISO6709", "+37.77-122.41/", .location)
    let make = item("qt.com.apple.quicktime.make", "Apple", .camera)
    let report = MetadataDiff.report(
        source: MetadataInventory(items: [make, location]),
        output: MetadataInventory(items: [make])
    )
    #expect(report.lost == [location])
    #expect(!report.isLossless)
}

@Test func differentValueIsChanged() {
    let src = item("video.dimensions", "3840x2160", .video)
    let out = item("video.dimensions", "1920x1080", .video)
    let report = MetadataDiff.report(
        source: MetadataInventory(items: [src]),
        output: MetadataInventory(items: [out])
    )
    #expect(
        report.changed == [
            MetadataChange(
                key: "video.dimensions", displayName: "video.dimensions",
                from: "3840x2160", to: "1920x1080")
        ])
    #expect(report.kept.isEmpty)
    #expect(report.lost.isEmpty)
}

@Test func extraOutputKeysIgnored() {
    let a = item("video.codec", "hvc1", .video)
    let extra = item("video.bitDepth", "10", .video)
    let report = MetadataDiff.report(
        source: MetadataInventory(items: [a]),
        output: MetadataInventory(items: [a, extra])
    )
    #expect(report.kept == [a])
    #expect(report.changed.isEmpty)
    #expect(report.lost.isEmpty)
}

@Test func reportOrderFollowsSource() {
    let items = [item("c", "1"), item("a", "2"), item("b", "3")]
    let report = MetadataDiff.report(
        source: MetadataInventory(items: items),
        output: MetadataInventory(items: items.reversed())
    )
    #expect(report.kept == items)
}

@Test func duplicateSourceKeyFirstWins() {
    let first = item("k", "1")
    let second = item("k", "2")
    let report = MetadataDiff.report(
        source: MetadataInventory(items: [first, second]),
        output: MetadataInventory(items: [first])
    )
    #expect(report.kept == [first])
    #expect(report.changed.isEmpty)
    #expect(report.lost.isEmpty)
}
