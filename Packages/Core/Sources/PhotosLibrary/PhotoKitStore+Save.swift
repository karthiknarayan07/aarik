import CoreLocation
import Foundation
import Photos
import Synchronization

/// The identifier PhotoKit hands out inside a change block, read after the block ran.
private final class PlaceholderBox: Sendable {
    private let value = Mutex<String?>(nil)
    func set(_ id: String?) { value.withLock { $0 = id } }
    var id: String? { value.withLock { $0 } }
}

extension PhotoKitStore {
    /// One `performChanges` that adds the asset (`.video` resource, `shouldMoveFile = false`), sets date,
    /// location, favorite, hidden and the caption (where the OS has it), and adds it to the albums that still exist, through its placeholder.
    @concurrent
    public func saveVideo(_ request: PhotoSaveRequest) async throws -> String {
        guard await authorization().allowsReading else { throw PhotoStoreError.notAuthorized }
        let albums = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: request.albums, options: nil)
        var candidates: [String: PHAssetCollection] = [:]
        albums.enumerateObjects { collection, _, _ in
            if collection.assetCollectionSubtype == .albumRegular, collection.canPerform(.addContent) {
                candidates[collection.localIdentifier] = collection
            }
        }
        let existing = request.albumsToAdd(existing: Set(candidates.keys)).compactMap { candidates[$0] }
        let placeholder = PlaceholderBox()
        do {
            try await PHPhotoLibrary.shared().performChanges { [existing] in
                let creation = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                creation.addResource(with: .video, fileURL: request.file, options: options)
                creation.creationDate = request.creationDate
                if let location = request.location {
                    creation.location = location.clLocation(timestamp: request.creationDate ?? Date())
                }
                creation.isFavorite = request.isFavorite
                creation.isHidden = request.isHidden
                if #available(macOS 27, iOS 27, *), let caption = request.caption, !caption.isEmpty {
                    creation.caption = caption
                }
                guard let created = creation.placeholderForCreatedAsset else { return }
                placeholder.set(created.localIdentifier)
                for collection in existing {
                    PHAssetCollectionChangeRequest(for: collection)?.addAssets([created] as NSArray)
                }
            }
        } catch {
            throw Self.mapTransferError(error)
        }
        guard let id = placeholder.id else {
            throw PhotoStoreError.unavailable("Photos gave no identifier; a video may have been added")
        }
        return id
    }

    /// `deleteAssets` in one change; Photos asks the user to confirm. A declined confirmation is a
    /// `CancellationError`.
    @concurrent
    public func deleteAssets(ids: [String]) async throws {
        guard await authorization().allowsReading else { throw PhotoStoreError.notAuthorized }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: Self.idFetchOptions())
        // Nothing is deleted, and the caller hears of it, when any asset can't be found.
        guard assets.count == Set(ids).count else {
            var found: Set<String> = []
            assets.enumerateObjects { asset, _, _ in found.insert(asset.localIdentifier) }
            throw PhotoStoreError.notInLibrary(ids.first { !found.contains($0) } ?? "")
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            }
        } catch {
            throw Self.mapTransferError(error)
        }
    }
}

extension PhotoLocation {
    /// The location as Photos wants it.
    func clLocation(timestamp: Date) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: altitude ?? 0, horizontalAccuracy: 0, verticalAccuracy: altitude == nil ? -1 : 0,
            timestamp: timestamp)
    }
}
