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
    /// location, favorite and hidden, and adds it to the albums that still exist, through its placeholder.
    @concurrent
    public func saveVideo(_ request: PhotoSaveRequest) async throws -> String {
        guard await authorization() == .authorized else { throw PhotoStoreError.notAuthorized }
        let albums = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: request.albums, options: nil)
        var existing: [PHAssetCollection] = []
        albums.enumerateObjects { collection, _, _ in
            if collection.assetCollectionSubtype == .albumRegular, collection.canPerform(.addContent) {
                existing.append(collection)
            }
        }
        let placeholder = PlaceholderBox()
        do {
            try await PHPhotoLibrary.shared().performChanges { [existing] in
                let creation = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                creation.addResource(with: .video, fileURL: request.file, options: options)
                creation.creationDate = request.creationDate
                if let location = request.location {
                    creation.location = CLLocation(
                        coordinate: CLLocationCoordinate2D(
                            latitude: location.latitude, longitude: location.longitude),
                        altitude: location.altitude, horizontalAccuracy: 0, verticalAccuracy: 0,
                        timestamp: request.creationDate ?? Date())
                }
                creation.isFavorite = request.isFavorite
                creation.isHidden = request.isHidden
                guard let created = creation.placeholderForCreatedAsset else { return }
                placeholder.set(created.localIdentifier)
                for collection in existing {
                    PHAssetCollectionChangeRequest(for: collection)?.addAssets([created] as NSArray)
                }
            }
        } catch {
            throw Self.mapTransferError(error)
        }
        guard let id = placeholder.id else { throw PhotoStoreError.unavailable("Photos gave no identifier") }
        return id
    }

    /// `deleteAssets` in one change; Photos asks the user to confirm. A declined confirmation is a
    /// `CancellationError`.
    @concurrent
    public func deleteAssets(ids: [String]) async throws {
        guard await authorization() == .authorized else { throw PhotoStoreError.notAuthorized }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        guard assets.count > 0 else { return }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            }
        } catch {
            throw Self.mapTransferError(error)
        }
    }
}
