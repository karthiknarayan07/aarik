import Foundation
import MediaTestSupport
import Testing

@testable import AppCore

@MainActor
@Suite("Platform seams")
struct PlatformSeamTests {
    @Test func powerSourceCarriesLowPowerMode() {
        let power = FakePowerSource()
        #expect(!power.snapshot.isLowPowerMode)
        var changes = 0
        power.observe { changes += 1 }
        power.set(PowerSnapshot(onBattery: true, percent: 80, isLowPowerMode: true))
        #expect(power.snapshot.isLowPowerMode)
        #expect(changes == 1)
    }

    @Test func coordinatorAppliesLowPowerModeFromTheSource() {
        let power = FakePowerSource()
        var latest: PressureEffect?
        let coordinator = PressureCoordinator(
            speed: .fastest, thermal: FakeThermalSource(), power: power, cores: FixedCores(),
            starter: FakeActivityStarter()
        ) { latest = $0 }
        coordinator.start()
        #expect((latest?.concurrencyLimit ?? 0) > 1)
        power.set(PowerSnapshot(onBattery: false, percent: nil, isLowPowerMode: true))
        #expect(latest?.concurrencyLimit == 1)
    }

    @Test func fakeTrasherRecordsAndCanFail() throws {
        let trasher = FakeFileTrasher()
        let moved = try trasher.moveToTrash(URL(filePath: "/tmp/a.mov"))
        #expect(trasher.trashed == [URL(filePath: "/tmp/a.mov")])
        #expect(moved.lastPathComponent == "a.mov")
        struct Boom: Error {}
        trasher.failure = Boom()
        #expect(throws: Boom.self) { try trasher.moveToTrash(URL(filePath: "/tmp/b.mov")) }
    }

    @Test func backgroundGrantExpiryReachesTheHolder() {
        let grant = FakeBackgroundGrant()
        var expired = false
        let token = grant.acquire(reason: "Converting", title: "Converting", subtitle: "1 of 3") { expired = true }
        #expect(grant.isHeld)
        grant.expire()
        #expect(expired)
        token.end()
        #expect(!grant.isHeld)
    }

    @Test func macAdapterGrantHoldsAnActivity() {
        let starter = FakeActivityStarter()
        let grant = ActivityBackgroundGrant(starter: starter)
        let token = grant.acquire(reason: "Converting", title: "", subtitle: "") {}
        #expect(starter.isHeld)
        token.end()
        #expect(!starter.isHeld)
    }

    @Test func pasteboardFakeKeepsTheLastCopy() {
        let board = FakePasteboard()
        board.copy(text: "a")
        board.copy(fileURLs: [URL(filePath: "/tmp/a.mov")])
        #expect(board.text == nil)
        #expect(board.fileURLs.count == 1)
    }

    @Test func dragOutOffersTheFile() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "drag-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = DragOut.itemProvider(for: url)
        #expect(!provider.registeredTypeIdentifiers.isEmpty)
    }
}

private struct FixedCores: CoreCounting {
    var counts: CoreCounts { CoreCounts(active: 8, performance: 4) }
}
