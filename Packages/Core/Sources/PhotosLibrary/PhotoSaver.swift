import AppCore
import CoreGraphics
import Foundation

/// Why a save to Photos did not end with a verified new asset.
public enum PhotoSaveError: Error, Sendable, Equatable, LocalizedError {
    /// Photos refused to add the video; no asset was made. The text is what PhotoKit said.
    case saveFailed(String)
    /// The new asset was added but is not what was saved (the reasons are in the list). `cleanup` says what
    /// happened to it.
    case verifyFailed(reasons: [String], cleanup: Cleanup)
    case cancelled

    /// What became of a new asset that failed verification.
    public enum Cleanup: Sendable, Equatable {
        /// Deleted again (Photos asked the user to confirm, and they did).
        case removed
        /// Photos found nothing to delete: the new asset is no longer there, but this call deleted nothing.
        case notFound
        /// The user declined the delete: the new asset is still in the library.
        case declined
        /// The delete failed; the new asset may still be in the library. The text is what PhotoKit said.
        case failed(String)
    }

    public var errorDescription: String? {
        switch self {
        case .saveFailed(let reason): "Couldn't add the video to Photos: \(reason)"
        case .verifyFailed(_, let cleanup):
            switch cleanup {
            case .removed:
                "The video added to Photos didn't check out, so it was removed. Your original is untouched."
            case .notFound:
                "The video added to Photos didn't check out, and Photos can no longer find it. Your original is "
                    + "untouched."
            case .declined:
                "The video added to Photos didn't check out. You chose to keep it; remove it in Photos if you "
                    + "don't want it. Your original is untouched."
            case .failed:
                "The video added to Photos didn't check out and couldn't be removed. Remove it in Photos. Your "
                    + "original is untouched."
            }
        case .cancelled: "Cancelled"
        }
    }
}

/// Saves a converted video to Photos as a new asset that looks like the source: same date, location, favorite and
/// hidden flags, and the same albums. It then checks what Photos stored.
///
/// The library changes only by adding that one asset. A source asset is never edited. After a failed check the new
/// asset is deleted again (Photos shows its confirmation); once a delete was attempted the saver never fetches
/// again, because a deleted asset can no longer be fetched.
public struct PhotoSaver: Sendable {
    /// Largest difference in duration, in seconds, between the source and the new asset.
    static let durationTolerance = 0.1
    /// Largest difference in creation date, in seconds.
    static let dateTolerance = 1.0
    /// Largest difference in coordinates, in degrees, between the source and the new asset.
    static let coordinateTolerance = 1e-4

    private let store: any PhotoStore

    public init(store: any PhotoStore) {
        self.store = store
    }

    /// Adds `file` (video) to Photos and returns the new asset's local identifier.
    public func save(
        file: URL, like source: PhotoAsset, albums: [String], expectedPixelSize: CGSize
    ) async throws -> String {
        try await save(
            file: file, mediaKind: .video, pairedVideoFile: nil, like: source, albums: albums,
            expectedPixelSize: expectedPixelSize)
    }

    /// Adds an image (or Live Photo, when `pairedVideoFile` is non-nil) to Photos, verifies metadata and size, and
    /// returns the new asset's local identifier.
    public func saveImage(
        file: URL, pairedVideoFile: URL? = nil, like source: PhotoAsset, albums: [String],
        expectedPixelSize: CGSize
    ) async throws -> String {
        try await save(
            file: file, mediaKind: .image, pairedVideoFile: pairedVideoFile, like: source, albums: albums,
            expectedPixelSize: expectedPixelSize)
    }

    private func save(
        file: URL, mediaKind: MediaKind, pairedVideoFile: URL?, like source: PhotoAsset, albums: [String],
        expectedPixelSize: CGSize
    ) async throws -> String {
        if Task.isCancelled { throw PhotoSaveError.cancelled }
        let request = PhotoSaveRequest(
            file: file, mediaKind: mediaKind, pairedVideoFile: pairedVideoFile, creationDate: source.creationDate,
            location: source.location, isFavorite: source.isFavorite, isHidden: source.isHidden,
            caption: source.caption, albums: albums)
        let newID: String
        do {
            newID =
                if mediaKind == .image {
                    try await store.saveImage(request)
                } else {
                    try await store.saveVideo(request)
                }
        } catch is CancellationError {
            throw PhotoSaveError.cancelled
        } catch {
            throw PhotoSaveError.saveFailed(error.localizedDescription)
        }
        let problems = await problems(
            with: newID, source: source, mediaKind: mediaKind, expectedLivePhoto: pairedVideoFile != nil,
            albums: albums, expectedPixelSize: expectedPixelSize)
        guard problems.isEmpty else {
            throw PhotoSaveError.verifyFailed(reasons: problems, cleanup: await remove(newID))
        }
        return newID
    }

    /// What is wrong with the new asset, in plain words; empty when it checks out.
    private func problems(
        with id: String, source: PhotoAsset, mediaKind: MediaKind, expectedLivePhoto: Bool, albums: [String],
        expectedPixelSize: CGSize
    ) async -> [String] {
        let stored: PhotoAsset
        do {
            stored = try await store.asset(id: id)
        } catch {
            return ["the new item can't be found in Photos"]
        }
        var problems: [String] = []
        if mediaKind == .video, abs(stored.duration - source.duration) > Self.durationTolerance {
            problems.append("its length is \(stored.duration) s, expected \(source.duration) s")
        }
        if expectedLivePhoto, !stored.subtypes.contains(.livePhoto) {
            problems.append("it was not saved as a Live Photo")
        }
        let swapped = CGSize(width: expectedPixelSize.height, height: expectedPixelSize.width)
        if stored.pixelSize != expectedPixelSize && stored.pixelSize != swapped {
            problems.append(
                "its size is \(Int(stored.pixelSize.width))x\(Int(stored.pixelSize.height)), expected "
                    + "\(Int(expectedPixelSize.width))x\(Int(expectedPixelSize.height))")
        }
        if (stored.originalByteSize ?? 0) <= 0 { problems.append("its file is empty") }
        if let expected = source.creationDate,
            abs(stored.creationDate?.timeIntervalSince(expected) ?? .infinity) > Self.dateTolerance
        {
            problems.append("its date differs from the original's")
        }
        if let expected = source.location, !Self.matches(stored.location, expected) {
            problems.append("its location differs from the original's")
        }
        if stored.isFavorite != source.isFavorite { problems.append("its favorite flag differs from the original's") }
        if stored.isHidden != source.isHidden { problems.append("its hidden flag differs from the original's") }
        if let caption = source.caption, !caption.isEmpty, stored.caption != caption {
            problems.append("its caption differs from the original's")
        }
        problems += await albumProblems(newID: id, source: source, requested: albums)
        return problems
    }

    /// The new asset must be in every requested album that still exists (one the source is still in). A read that
    /// fails proves nothing either way, so it adds no problem.
    private func albumProblems(newID: String, source: PhotoAsset, requested: [String]) async -> [String] {
        guard !requested.isEmpty, let stillThere = try? await store.albums(containing: source.id),
            let actual = try? await store.albums(containing: newID)
        else { return [] }
        let expected = Set(requested).intersection(stillThere)
        let missing = expected.subtracting(actual)
        return missing.isEmpty ? [] : ["it is not in \(missing.count) of the original's albums"]
    }

    private static func matches(_ actual: PhotoLocation?, _ expected: PhotoLocation) -> Bool {
        guard let actual else { return false }
        return abs(actual.latitude - expected.latitude) < coordinateTolerance
            && abs(actual.longitude - expected.longitude) < coordinateTolerance
    }

    /// Deletes the new asset. Nothing is fetched afterwards.
    private func remove(_ id: String) async -> PhotoSaveError.Cleanup {
        do {
            try await store.deleteAssets(ids: [id])
            return .removed
        } catch is CancellationError {
            return .declined
        } catch PhotoStoreError.notInLibrary {
            return .notFound
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

extension PhotoSaveError: OutcomeCoded {
    public var outcomeCode: OutcomeCode {
        switch self {
        case .saveFailed, .verifyFailed: .photosSaveFailed
        case .cancelled: .cancelled
        }
    }
}
