import Foundation
import Photos
import Synchronization
import Testing

@testable import PhotosLibrary

/// The request bookkeeping around PhotoKit calls, with no library involved.
@Suite struct PhotoKitRequestTests {
    private func tempFile() throws -> (URL, FileHandle) {
        let url = FileManager.default.temporaryDirectory.appending(path: "RequestTests-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return (url, try FileHandle(forWritingTo: url))
    }

    // MARK: - Cancel between start and setID

    @Test func cancelBeforeTheIDIsKnownMakesSetIDRequestACancel() throws {
        let (url, file) = try tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let transfer = ResourceTransfer(file: file, cancelRequest: { _ in })
        #expect(transfer.cancel() == nil, "no id yet to cancel")
        #expect(transfer.setID(7), "the caller must cancel request 7 now")
    }

    @Test func setIDBeforeCancelIsNotAnImmediateCancel() throws {
        let (url, file) = try tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let transfer = ResourceTransfer(file: file, cancelRequest: { _ in })
        #expect(!transfer.setID(7))
        #expect(transfer.cancel() == 7)
    }

    @Test func exportRequestCancelledBeforeItsIDIsKnown() {
        let request = ExportSessionRequest()
        #expect(request.cancel() == nil)
        #expect(request.setID(5))
        let live = ExportSessionRequest()
        #expect(!live.setID(5))
        #expect(live.cancel() == 5)
    }

    // MARK: - Write failure

    @Test func aWriteFailureCancelsTheRequest() async throws {
        let (url, file) = try tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let cancelled = Mutex<[PHAssetResourceDataRequestID]>([])
        let transfer = ResourceTransfer(file: file, cancelRequest: { id in cancelled.withLock { $0.append(id) } })
        #expect(!transfer.setID(9))
        // A closed handle makes the next write fail, like a full disk.
        try file.close()
        let result = await withCheckedContinuation { outer in
            Task {
                do {
                    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                        _ = transfer.start(c)
                        transfer.receive(Data([1, 2, 3]))
                    }
                    outer.resume(returning: "finished")
                } catch {
                    outer.resume(returning: (error as? PhotoStoreError).map { "\($0)" } ?? "other")
                }
            }
        }
        #expect(result.hasPrefix("unavailable"))
        #expect(cancelled.withLock { $0 } == [9])
        // Later chunks and the completion are ignored.
        transfer.receive(Data([4]))
        transfer.finish(nil)
    }

    @Test func aWriteFailureBeforeTheIDIsKnownIsCancelledBySetID() async throws {
        let (url, file) = try tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let cancelled = Mutex(0)
        let transfer = ResourceTransfer(file: file, cancelRequest: { _ in cancelled.withLock { $0 += 1 } })
        try file.close()
        _ = await withCheckedContinuation { (outer: CheckedContinuation<Bool, Never>) in
            Task {
                _ = try? await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                    _ = transfer.start(c)
                    transfer.receive(Data([1]))
                }
                outer.resume(returning: true)
            }
        }
        #expect(cancelled.withLock { $0 } == 0, "no id yet, so nothing to cancel")
        #expect(transfer.setID(3), "setID reports the request is over")
    }

    // MARK: - Close versus write

    @Test func writesAfterACancelAreIgnoredAndTheFileStaysClosedOnce() throws {
        let (url, file) = try tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let transfer = ResourceTransfer(file: file, cancelRequest: { _ in })
        transfer.receive(Data([1, 2]))
        _ = transfer.cancel()
        transfer.receive(Data([3, 4]))
        transfer.finish(nil)
        #expect(try Data(contentsOf: url) == Data([1, 2]))
    }
}
