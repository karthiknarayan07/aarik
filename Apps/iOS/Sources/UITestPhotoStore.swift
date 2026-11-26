#if DEBUG
    import AppCore
    import CoreGraphics
    import Foundation
    import PhotosLibrary

    /// A debug-only stand-in that makes the Simulator's Photos library behave like an iPhone's, for UI tests:
    /// - `-uiTestingPhotos limited|denied|restricted|notDetermined` reports that Photos access state (a denied or
    ///   restricted library lists nothing; "not determined" stays so when the app asks, as if the sheet were dismissed);
    /// - `-uiTestingICloud <seconds>` marks every video as iCloud-only: fetching one takes that long, reporting
    ///   `.downloading` progress, before the real (local) copy is handed over.
    /// Everything else is the real `PhotoKitStore`, so the fixtures still convert for real.
    struct UITestPhotoStore: PhotoStore {
        let base: any PhotoStore
        /// nil leaves the real answer.
        let authorizationOverride: PhotoAuthorization?
        /// nil leaves videos where they are; a number of seconds makes them iCloud-only for that long a download.
        let downloadSeconds: Double?

        /// The stand-in the launch arguments ask for, or the real store when they ask for none.
        static func make(arguments: [String], base: any PhotoStore) -> any PhotoStore {
            let state = LaunchArguments.value(of: "-uiTestingPhotos", in: arguments).flatMap(parse)
            let seconds = LaunchArguments.value(of: "-uiTestingICloud", in: arguments).flatMap(Double.init)
            guard state != nil || seconds != nil else { return base }
            return UITestPhotoStore(base: base, authorizationOverride: state, downloadSeconds: seconds)
        }

        private static func parse(_ text: String) -> PhotoAuthorization? {
            switch text {
            case "limited": .limited
            case "denied": .denied
            case "restricted": .restricted
            case "notDetermined": .notDetermined
            default: nil
            }
        }

        func authorization() async -> PhotoAuthorization {
            if let authorizationOverride { return authorizationOverride }
            return await base.authorization()
        }

        func requestAuthorization() async -> PhotoAuthorization {
            if let authorizationOverride { return authorizationOverride }
            return await base.requestAuthorization()
        }

        func videos() async throws -> [PhotoAsset] {
            if let authorizationOverride, !authorizationOverride.allowsReading { throw PhotoStoreError.notAuthorized }
            let assets = try await base.videos()
            guard downloadSeconds != nil else { return assets }
            return assets.map(Self.iCloudOnly)
        }

        func changes() -> AsyncStream<Void> { base.changes() }

        func albums(containing id: String) async throws -> [String] { try await base.albums(containing: id) }

        func thumbnail(for id: String, size: CGSize) async -> CGImage? { await base.thumbnail(for: id, size: size) }

        func asset(id: String) async throws -> PhotoAsset {
            let asset = try await base.asset(id: id)
            return downloadSeconds == nil ? asset : Self.iCloudOnly(asset)
        }

        func saveVideo(_ request: PhotoSaveRequest) async throws -> String { try await base.saveVideo(request) }

        func deleteAssets(ids: [String]) async throws { try await base.deleteAssets(ids: ids) }

        func writeOriginal(id: String, to url: URL, progress: @escaping @Sendable (FetchProgress) -> Void) async throws
        {
            try await simulateDownload(progress: progress)
            try await base.writeOriginal(id: id, to: url, progress: { _ in })
        }

        func exportCurrentVersion(
            id: String, to url: URL, progress: @escaping @Sendable (FetchProgress) -> Void
        ) async throws {
            try await simulateDownload(progress: progress)
            try await base.exportCurrentVersion(id: id, to: url, progress: { _ in })
        }

        /// Counts the download from 0 to 1 over `downloadSeconds`; cancelling the task stops it, like a real transfer.
        private func simulateDownload(progress: @escaping @Sendable (FetchProgress) -> Void) async throws {
            guard let downloadSeconds else { return }
            let steps = max(Int(downloadSeconds * 5), 1)
            for step in 0...steps {
                try Task.checkCancellation()
                progress(.downloading(Double(step) / Double(steps)))
                if step < steps { try await Task.sleep(for: .seconds(downloadSeconds / Double(steps))) }
            }
        }

        private static func iCloudOnly(_ asset: PhotoAsset) -> PhotoAsset {
            PhotoAsset(
                id: asset.id, creationDate: asset.creationDate, location: asset.location, pixelSize: asset.pixelSize,
                duration: asset.duration, isFavorite: asset.isFavorite, isHidden: asset.isHidden,
                hasAdjustments: asset.hasAdjustments, subtypes: asset.subtypes,
                originalFileName: asset.originalFileName, originalByteSize: asset.originalByteSize,
                isLocallyAvailable: false, modificationDate: asset.modificationDate)
        }
    }
#endif
