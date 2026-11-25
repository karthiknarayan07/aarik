import Foundation
import Testing

@testable import PhotosLibrary

/// How PhotoKit's errors become store errors; pure, so it needs no library.
@Suite struct PhotoKitErrorMappingTests {
    private func map(_ domain: String, _ code: Int) -> any Error {
        PhotoKitStore.mapTransferError(NSError(domain: domain, code: code))
    }

    @Test(arguments: [3164, 3169])
    func networkErrorsAreDownloadFailures(code: Int) {
        let error = map("PHPhotosErrorDomain", code) as? PhotoStoreError
        guard case .downloadFailed(let text)? = error else {
            Issue.record("expected downloadFailed, got \(String(describing: error))")
            return
        }
        #expect(text.contains("\(code)"))
    }

    @Test func offlineURLErrorsAreDownloadFailures() {
        let error = map(NSURLErrorDomain, NSURLErrorNotConnectedToInternet) as? PhotoStoreError
        guard case .downloadFailed? = error else {
            Issue.record("expected downloadFailed")
            return
        }
    }

    @Test func userCancelledIsACancellation() {
        #expect(map("PHPhotosErrorDomain", 3072) is CancellationError)
    }

    @Test func otherErrorsAreUnavailableNotDownloadFailures() {
        let error = map("PHPhotosErrorDomain", 3300) as? PhotoStoreError
        guard case .unavailable? = error else {
            Issue.record("expected unavailable")
            return
        }
    }

    @Test func storeErrorsPassThrough() {
        let error = PhotoKitStore.mapTransferError(PhotoStoreError.notInLibrary("x"))
        #expect(error as? PhotoStoreError == .notInLibrary("x"))
    }
}
