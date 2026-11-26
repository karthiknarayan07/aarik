#if DEBUG
    import CoreGraphics
    import Foundation
    import PhotosLibrary

    /// Debug-only Photos library for the scroll performance test (`-uiTestingFakePhotos <count>`): `count` videos with
    /// metadata like a real library (several per day, mixed shapes, sizes and badges) and a generated poster per
    /// request, drawn off the main thread. It never touches the real library.
    struct SyntheticPhotoStore: PhotoStore {
        private let inner: FakePhotoStore

        init(count: Int) {
            let calendar = Calendar(identifier: .gregorian)
            let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 25)) ?? Date()
            let assets = (0..<count).map { index -> PhotoAsset in
                let landscape = index % 5 != 0
                let size = landscape ? CGSize(width: 3840, height: 2160) : CGSize(width: 2160, height: 3840)
                var subtypes: PhotoSubtypes = []
                if index % 11 == 0 { subtypes.insert(.highFrameRate) }
                if index % 17 == 0 { subtypes.insert(.cinematic) }
                return PhotoAsset(
                    id: "synthetic-\(index)", creationDate: start.addingTimeInterval(-Double(index) * 4 * 3600),
                    pixelSize: size, duration: Double(5 + index % 120), isFavorite: index % 7 == 0,
                    subtypes: subtypes, originalFileName: String(format: "IMG_%04d.MOV", index),
                    originalByteSize: Int64(20_000_000 + (index * 7_919) % 900_000_000),
                    isLocallyAvailable: index % 9 != 0, modificationDate: start)
            }
            inner = FakePhotoStore(assets: assets, authorization: .authorized)
        }

        func authorization() async -> PhotoAuthorization { await inner.authorization() }
        func requestAuthorization() async -> PhotoAuthorization { await inner.requestAuthorization() }
        func videos() async throws -> [PhotoAsset] { try await inner.videos() }
        func changes() -> AsyncStream<Void> { inner.changes() }
        func albums(containing id: String) async throws -> [String] { try await inner.albums(containing: id) }
        func asset(id: String) async throws -> PhotoAsset { try await inner.asset(id: id) }
        func saveVideo(_ request: PhotoSaveRequest) async throws -> String { try await inner.saveVideo(request) }
        func deleteAssets(ids: [String]) async throws { try await inner.deleteAssets(ids: ids) }

        func writeOriginal(id: String, to url: URL, progress: @escaping @Sendable (FetchProgress) -> Void)
            async throws
        {
            try await inner.writeOriginal(id: id, to: url, progress: progress)
        }

        func exportCurrentVersion(
            id: String, to url: URL, progress: @escaping @Sendable (FetchProgress) -> Void
        ) async throws {
            try await inner.exportCurrentVersion(id: id, to: url, progress: progress)
        }

        @concurrent
        func thumbnail(for id: String, size: CGSize) async -> CGImage? {
            let width = max(1, Int(size.width))
            let height = max(1, Int(size.height))
            guard
                let context = CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            let hue = Double(abs(id.hashValue % 360)) / 360
            let top = CGColor(red: hue, green: 0.5, blue: 0.8, alpha: 1)
            let bottom = CGColor(red: 0.1, green: hue, blue: 0.4, alpha: 1)
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top, bottom] as CFArray, locations: [0, 1])
            {
                context.drawLinearGradient(
                    gradient, start: .zero, end: CGPoint(x: CGFloat(width), y: CGFloat(height)), options: [])
            }
            return context.makeImage()
        }
    }
#endif
