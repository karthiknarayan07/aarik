import Foundation
import Testing

@testable import AarikCore

/// Several jobs at once share one disk: what a running job has promised to write counts against the others.
@Suite("Space reservations")
struct SpaceLedgerTests {
    private static let gb: Int64 = 1_000_000_000
    private let here = URL(filePath: "/Volumes/Work/a/b.mov")

    private func check(available: Int64) -> DiskSpaceCheck {
        DiskSpaceCheck(provider: FakeDiskSpace(available: available), ledger: SpaceLedger())
    }

    @Test func theSecondJobFailsWhenTheFirstsReservationLeavesTooLittle() throws {
        // 4 GB free; each job needs 2 GB plus the margin. Alone each fits; together they don't.
        let disk = check(available: 4 * Self.gb)
        let (first, second) = (UUID(), UUID())
        try disk.verify([SpaceNeed(url: here, bytes: 2 * Self.gb)], reservingFor: first)

        #expect(throws: NotEnoughSpaceError.self) {
            try disk.verify([SpaceNeed(url: here, bytes: 2 * Self.gb)], reservingFor: second)
        }
        // A job without an owner (the plain check) is unaffected.
        try disk.verify([SpaceNeed(url: here, bytes: 2 * Self.gb)])
    }

    @Test func releasingMakesRoomAgain() throws {
        let disk = check(available: 4 * Self.gb)
        let (first, second) = (UUID(), UUID())
        try disk.verify([SpaceNeed(url: here, bytes: 2 * Self.gb)], reservingFor: first)
        disk.release(owner: first)
        try disk.verify([SpaceNeed(url: here, bytes: 2 * Self.gb)], reservingFor: second)
    }

    @Test func aFailedCheckReservesNothing() throws {
        let disk = check(available: 4 * Self.gb)
        let (big, small) = (UUID(), UUID())
        #expect(throws: NotEnoughSpaceError.self) {
            try disk.verify([SpaceNeed(url: here, bytes: 9 * Self.gb)], reservingFor: big)
        }
        try disk.verify([SpaceNeed(url: here, bytes: 3 * Self.gb)], reservingFor: small)
    }

    @Test func theMarginIsKeptOncePerVolumeNotOncePerJob() throws {
        // Two 1 GB jobs and one 1 GB margin: 3 GB is enough, 3 GB - 1 byte is not.
        let enough = check(available: 3 * Self.gb)
        try enough.verify([SpaceNeed(url: here, bytes: Self.gb)], reservingFor: UUID())
        try enough.verify([SpaceNeed(url: here, bytes: Self.gb)], reservingFor: UUID())

        let short = check(available: 3 * Self.gb - 1)
        try short.verify([SpaceNeed(url: here, bytes: Self.gb)], reservingFor: UUID())
        #expect(throws: NotEnoughSpaceError.self) {
            try short.verify([SpaceNeed(url: here, bytes: Self.gb)], reservingFor: UUID())
        }
    }

    @Test func aJobsSecondEstimateReplacesItsFirstInsteadOfAddingToIt() throws {
        let disk = check(available: 4 * Self.gb)
        let job = UUID()
        try disk.verify([SpaceNeed(url: here, bytes: 2 * Self.gb)], reservingFor: job)
        // The exact estimate is checked again; counting its own earlier promise would fail it.
        try disk.verify([SpaceNeed(url: here, bytes: 2 * Self.gb)], reservingFor: job)
    }
}
