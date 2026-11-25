#if DEBUG
    import AppCore
    import CoreLocation
    import Foundation
    import MediaEngine
    import Photos
    import Synchronization

    /// Identifiers handed out while a Photos change runs.
    private final class Placeholders: Sendable {
        private let ids = Mutex<(asset: String?, album: String?)>((nil, nil))

        func set(asset: String?, album: String?) { ids.withLock { $0 = (asset, album) } }
        var asset: String? { ids.withLock { $0.asset } }
        var album: String? { ids.withLock { $0.album } }
    }

    extension SpikeRunner {
        private static let testDate = Date(timeIntervalSince1970: 1_623_758_400)  // 2021-06-15 12:00 UTC
        private static let testLocation = CLLocation(latitude: 12.5, longitude: 45.25)

        /// Saves the generated clip with metadata into a temporary album, reads it back, writes its resource out,
        /// then deletes the asset and the album.
        func saveRoundTrip() async throws {
            let clip = clipURL()
            guard FileManager.default.fileExists(atPath: clip.path) else {
                log.line("SAVE skipped: no test clip at \(clip.path)")
                return
            }
            guard !(try albumExists()) else {
                log.line("SAVE skipped: an album titled \"\(Self.albumTitle)\" already exists; not touching it")
                return
            }
            let source = try await MediaInspector().inventory(of: clip)
            log.inventory("INVENTORY test clip as generated (\(fileSize(clip)) bytes)", source)

            let placeholders = Placeholders()
            let started = Date()
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                request.addResource(with: .video, fileURL: clip, options: options)
                request.creationDate = Self.testDate
                request.location = Self.testLocation
                request.isFavorite = true
                request.isHidden = false
                let album = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(
                    withTitle: Self.albumTitle)
                if let placeholder = request.placeholderForCreatedAsset {
                    album.addAssets([placeholder] as NSArray)
                }
                placeholders.set(
                    asset: request.placeholderForCreatedAsset?.localIdentifier,
                    album: album.placeholderForCreatedAssetCollection.localIdentifier)
            }
            log.line("SAVE created in \(seconds(since: started)) (no system dialog is expected for adding)")
            guard let assetID = placeholders.asset, let albumID = placeholders.album else {
                log.line("SAVE no placeholder identifiers")
                return
            }
            do {
                try await verify(assetID: assetID, albumID: albumID, source: source, clip: clip)
            } catch {
                log.line("VERIFY failed: \(describe(error))")
            }
            await cleanUp(assetID: assetID, albumID: albumID)
        }

        private func clipURL() -> URL {
            if let path = Self.argument("-photosSpikeClip") { return URL(fileURLWithPath: path) }
            return tempFolder.appending(path: "test-clip.mov")
        }

        private func albumExists() throws -> Bool {
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "title = %@", Self.albumTitle)
            return PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options).count > 0
        }

        private func verify(assetID: String, albumID: String, source: MetadataInventory, clip: URL) async throws {
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else {
                log.line("VERIFY asset not found after save")
                return
            }
            let location = asset.location
            log.line(
                "VERIFY asset: type=\(asset.mediaType.rawValue) subtypes=\(asset.mediaSubtypes.rawValue) "
                    + "size=\(asset.pixelWidth)x\(asset.pixelHeight) duration=\(asset.duration) "
                    + "hasAdjustments=\(asset.hasAdjustments) source=\(asset.sourceType.rawValue)")
            log.line(
                "VERIFY creationDate matches=\(asset.creationDate == Self.testDate) "
                    + "location matches=\(location.map { abs($0.coordinate.latitude - 12.5) < 1e-4 && abs($0.coordinate.longitude - 45.25) < 1e-4 } ?? false) "
                    + "isFavorite=\(asset.isFavorite) isHidden=\(asset.isHidden)")
            let albums = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil)
            if let album = albums.firstObject {
                let inAlbum = PHAsset.fetchAssets(in: album, options: nil)
                log.line(
                    "VERIFY album \"\(album.localizedTitle ?? "")\" holds \(inAlbum.count) asset(s); "
                        + "contains test asset=\(inAlbum.contains(asset))")
            } else {
                log.line("VERIFY album not found")
            }
            let resources = PHAssetResource.assetResources(for: asset)
            log.line("VERIFY resources: \(resources.map { resourceTypeName($0.type) }.joined(separator: ", "))")
            guard let video = resources.first(where: { $0.type == .video }) else { return }
            let back = tempFolder.appending(path: "roundtrip.mov")
            try await write(video, to: back)
            log.line("ROUNDTRIP .video written back: \(fileSize(back)) bytes (generated clip: \(fileSize(clip)) bytes)")
            let after = try await MediaInspector().inventory(of: back)
            log.inventory("INVENTORY round-trip .video", after)
            log.diff("test clip -> Photos .video", MetadataDiff.report(source: source, output: after), source: source)
        }

        // MARK: - Delete

        /// Deletes the test asset (the system asks the owner to confirm), then the test album.
        private func cleanUp(assetID: String, albumID: String) async {
            if let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject {
                log.line("DELETE asking Photos to delete the test asset; waiting for the system confirmation")
                let started = Date()
                do {
                    try await PHPhotoLibrary.shared().performChanges {
                        PHAssetChangeRequest.deleteAssets([asset] as NSArray)
                    }
                    log.line("DELETE asset deleted after \(seconds(since: started)) (the confirmation was accepted)")
                } catch {
                    log.line("DELETE asset not deleted after \(seconds(since: started)): \(describe(error))")
                }
            }
            reportTrash(assetID: assetID)
            if let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil)
                .firstObject
            {
                let started = Date()
                do {
                    try await PHPhotoLibrary.shared().performChanges {
                        PHAssetCollectionChangeRequest.deleteAssetCollections([album] as NSArray)
                    }
                    log.line("DELETE album deleted in \(seconds(since: started)) (waited for any dialog)")
                } catch {
                    log.line("DELETE album not deleted: \(describe(error))")
                }
            }
            let left = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).count
            log.line("DELETE album still present=\(left > 0)")
            log.line("SPIKE cleanup finished")
        }

        /// What PhotoKit can say about a deleted asset: whether a fetch still finds it, and the smart albums.
        private func reportTrash(assetID: String) {
            let found = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
            log.line("TRASH fetch by identifier after delete finds \(found.count) asset(s)")
            if let asset = found.firstObject {
                log.line("TRASH trashedState key=\(String(describing: keyValue(asset, "trashedState")))")
            }
            let smart = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .any, options: nil)
            var titles: [String] = []
            smart.enumerateObjects { collection, _, _ in
                titles.append("\(collection.localizedTitle ?? "?")(\(collection.assetCollectionSubtype.rawValue))")
            }
            log.line("TRASH smart albums visible to PhotoKit: \(titles.joined(separator: ", "))")
        }
    }
#endif
