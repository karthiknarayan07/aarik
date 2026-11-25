import Foundation
import Testing

@testable import AppCore

@Suite("Disk space check")
struct DiskSpaceTests {
    private static let gb: Int64 = 1_000_000_000
    private let here = URL(filePath: "/Volumes/Work/a/b.mov")

    @Test func enoughRoomPasses() throws {
        let check = DiskSpaceCheck(provider: FakeDiskSpace(available: 5 * Self.gb))
        try check.verify([SpaceNeed(url: here, bytes: 3 * Self.gb)])
    }

    @Test func theMarginIsPartOfTheNeed() {
        // 3 GB of output with the 1 GB margin needs 4 GB: 3.9 GB free is not enough, 4 GB is.
        let short = DiskSpaceCheck(provider: FakeDiskSpace(available: 4 * Self.gb - 1))
        #expect(throws: NotEnoughSpaceError.self) { try short.verify([SpaceNeed(url: here, bytes: 3 * Self.gb)]) }
        let exact = DiskSpaceCheck(provider: FakeDiskSpace(available: 4 * Self.gb))
        #expect(throws: Never.self) { try exact.verify([SpaceNeed(url: here, bytes: 3 * Self.gb)]) }
    }

    @Test func needsOnOneVolumeAddUp() {
        // Download 2 GB + output 2 GB + margin 1 GB = 5 GB on the same volume.
        let check = DiskSpaceCheck(provider: FakeDiskSpace(available: 4 * Self.gb))
        #expect(throws: NotEnoughSpaceError.self) {
            try check.verify([
                SpaceNeed(url: here, bytes: 2 * Self.gb), SpaceNeed(url: here.appending(path: "x"), bytes: 2 * Self.gb),
            ])
        }
    }

    @Test func eachVolumeIsCheckedOnItsOwn() throws {
        let disk = FakeDiskSpace(available: 100 * Self.gb)
        disk.setVolume(at: URL(filePath: "/Volumes/Backup"), name: "Backup", available: 2 * Self.gb)
        let check = DiskSpaceCheck(provider: disk)

        // 1.5 GB on the roomy volume and on the backup volume: only the backup volume is short.
        let error = #expect(throws: NotEnoughSpaceError.self) {
            try check.verify([
                SpaceNeed(url: here, bytes: Self.gb * 3 / 2),
                SpaceNeed(url: URL(filePath: "/Volumes/Backup/Originals/a.mov"), bytes: Self.gb * 3 / 2),
            ])
        }
        #expect(error?.volumeName == "Backup")
        #expect(error?.availableBytes == 2 * Self.gb)
        #expect(error?.neededBytes == Self.gb * 5 / 2)
    }

    @Test func theLongestMatchingVolumeRootWins() {
        let disk = FakeDiskSpace(available: 100 * Self.gb)
        disk.setVolume(at: URL(filePath: "/Volumes/Big"), name: "Big", available: 50 * Self.gb)
        disk.setVolume(at: URL(filePath: "/Volumes/Big/Mounted"), name: "Mounted", available: 10)
        #expect(disk.volume(containing: URL(filePath: "/Volumes/Big/Mounted/x.mov"))?.name == "Mounted")
        #expect(disk.volume(containing: URL(filePath: "/Volumes/Big/Other/x.mov"))?.name == "Big")
        // "/Volumes/BigGer" is not inside "/Volumes/Big".
        #expect(disk.volume(containing: URL(filePath: "/Volumes/BigGer/x.mov"))?.name == "Fake")
    }

    @Test func aVolumeThatCantBeReadIsNotChecked() throws {
        let check = DiskSpaceCheck(provider: FakeDiskSpace(fallback: nil))
        try check.verify([SpaceNeed(url: here, bytes: Int64.max)])
    }

    @Test func hugeNeedsDontOverflow() {
        let check = DiskSpaceCheck(provider: FakeDiskSpace(available: 10 * Self.gb))
        #expect(throws: NotEnoughSpaceError.self) {
            try check.verify([SpaceNeed(url: here, bytes: Int64.max), SpaceNeed(url: here, bytes: Int64.max)])
        }
    }

    @Test func theMessageNamesTheVolumeAndBothSizes() {
        let error = NotEnoughSpaceError(
            volumeName: "Macintosh HD", neededBytes: 4 * Self.gb, availableBytes: 2 * Self.gb)
        let formatter = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        #expect(
            error.localizedDescription
                == "Not enough free space on Macintosh HD (needs about \(formatter(4 * Self.gb)), "
                + "has \(formatter(2 * Self.gb)))")
        #expect(error.localizedDescription.contains("4 GB"))
    }

    @Test func theRealDiskAnswersForAFolderThatDoesNotExistYet() throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: "no-such-\(UUID().uuidString)/Work/job")
        let volume = try #require(SystemDiskSpace().volume(containing: missing))
        #expect(!volume.name.isEmpty)
        #expect(volume.availableBytes > 0)
        // Asking creates nothing.
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }
}
