import AppCore
import Foundation

/// A Photos video fetched into the work folder, ready to convert.
public struct FetchedInput: Sendable, Equatable {
    public let url: URL
    /// True when the file is Photos' rendering of the edited version; false for the original resource.
    public let isEditedVersion: Bool
    public let bytes: Int64
    /// The video as Photos described it when the fetch began, before anything was downloaded: the baseline for
    /// "did it change meanwhile" (a download can take many minutes) and the source of the copy's date and location.
    public let asset: PhotoAsset

    public init(url: URL, isEditedVersion: Bool, bytes: Int64, asset: PhotoAsset) {
        self.url = url
        self.isEditedVersion = isEditedVersion
        self.bytes = bytes
        self.asset = asset
    }
}

public enum PhotoFetchError: Error, Sendable, Equatable, LocalizedError {
    /// The video was deleted from Photos.
    case notInLibrary
    /// The video had to come from iCloud and could not (offline, refused, or the download failed). `underlying` is
    /// what PhotoKit said, for the log.
    case downloadFailed(underlying: String)
    case cancelled
    /// Any other reason Photos could not give the video.
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notInLibrary: "No longer in your Photos library"
        case .downloadFailed: "Couldn't download from iCloud. Check that you're online and try again."
        case .cancelled: "Cancelled"
        case .failed(let reason): "Couldn't get the video from Photos: \(reason)"
        }
    }
}

/// Gets the input for a Photos job: the video's current version, written into a work folder.
///
/// - Unedited video: the original resource, written as it is (`PhotoStore.writeOriginal`).
/// - Edited video: Photos' rendering of the current version, through an export session
///   (`PhotoStore.exportCurrentVersion`).
///
/// Both may download from iCloud, which is the only network use in the app, and only for a queued job. Progress
/// reports the download as its own phase, then the export. A failure or a cancel removes the partly written file,
/// so nothing is left in the work folder.
public struct PhotoInputFetcher: Sendable {
    private let store: any PhotoStore

    public init(store: any PhotoStore) {
        self.store = store
    }

    /// The video's current metadata (whether it was edited, its duration and so on), without downloading anything.
    ///
    /// - Throws: `PhotoFetchError` only.
    public func asset(id: String) async throws -> PhotoAsset {
        do {
            return try await store.asset(id: id)
        } catch {
            throw Self.map(error)
        }
    }

    /// Fetches `id` into `workFolder` (which must exist; see `WorkFolder.create(for:)`).
    ///
    /// - Throws: `PhotoFetchError` only.
    public func fetch(
        id: String, into workFolder: URL, progress: @escaping @Sendable (FetchProgress) -> Void = { _ in }
    ) async throws -> FetchedInput {
        try await fetch(id: id, into: workFolder, originalOnly: false, progress: progress)
    }

    /// Fetches the original resource of `id` even when the video was edited, for a copy of the original kept
    /// before a Replace. Its file keeps the original's name, so it sits beside the edited version's export.
    ///
    /// - Throws: `PhotoFetchError` only.
    public func fetchOriginal(
        id: String, into workFolder: URL, progress: @escaping @Sendable (FetchProgress) -> Void = { _ in }
    ) async throws -> FetchedInput {
        try await fetch(id: id, into: workFolder, originalOnly: true, progress: progress)
    }

    private func fetch(
        id: String, into workFolder: URL, originalOnly: Bool, progress: @escaping @Sendable (FetchProgress) -> Void
    ) async throws -> FetchedInput {
        let asset: PhotoAsset
        do {
            asset = try await store.asset(id: id)
            try Task.checkCancellation()
        } catch {
            throw Self.map(error)
        }
        let isEdited = asset.hasAdjustments && !originalOnly
        let url = workFolder.appending(
            path: Self.fileName(for: asset, isEdited: isEdited), directoryHint: .notDirectory)
        // Every delete goes through the containment check: only a file inside the job folder is removed.
        let jobFolder = WorkFolder(root: workFolder)
        jobFolder.remove(url)
        do {
            if isEdited {
                try await store.exportCurrentVersion(id: id, to: url, progress: progress)
            } else {
                try await store.writeOriginal(id: id, to: url, progress: progress)
            }
            try Task.checkCancellation()
            let bytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            guard bytes > 0 else { throw PhotoFetchError.failed("Photos wrote an empty file.") }
            return FetchedInput(url: url, isEditedVersion: isEdited, bytes: bytes, asset: asset)
        } catch {
            jobFolder.remove(url)
            throw Self.map(error)
        }
    }

    /// The original's own name (its last path component only), or the same stem with `-edited.mov` for the
    /// export, so a second fetch of the original into the same folder keeps its own file.
    public static func fileName(for asset: PhotoAsset, isEdited: Bool) -> String {
        var name = asset.originalFileName.split(separator: "/").last.map(String.init) ?? ""
        // A name that is empty or points at the folder itself or its parent is never used as a file name.
        if ["", ".", "..", "/"].contains(name) { name = "video.mov" }
        guard isEdited else { return name }
        return (name as NSString).deletingPathExtension + "-edited.mov"
    }

    static func map(_ error: any Error) -> PhotoFetchError {
        if let fetch = error as? PhotoFetchError { return fetch }
        if error is CancellationError || Task.isCancelled { return .cancelled }
        switch error as? PhotoStoreError {
        case .notInLibrary: return .notInLibrary
        case .downloadFailed(let reason): return .downloadFailed(underlying: reason)
        case .unavailable(let reason): return .failed(reason)
        case .notAuthorized, nil: return .failed(error.localizedDescription)
        }
    }
}

extension PhotoFetchError: OutcomeCoded {
    public var outcomeCode: OutcomeCode {
        switch self {
        case .notInLibrary: .originalUnavailable
        case .downloadFailed: .iCloudDownloadFailed
        case .cancelled: .cancelled
        case .failed: .originalUnavailable
        }
    }
}
