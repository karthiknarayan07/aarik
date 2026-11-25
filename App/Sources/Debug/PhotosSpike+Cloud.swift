#if DEBUG
    import AppCore
    import Foundation
    import MediaEngine
    import Photos

    extension SpikeRunner {
        /// One edited clip whose rendering is still in iCloud (both resources under 60 MB, so the download is small):
        /// does the export session refuse without network access, and what do `.fullSizeVideo` and the export keep?
        func editedCloudRendering(_ facts: [VideoFacts]) async throws {
            let candidates = facts.filter(\.isCloudEditedCandidate)
            log.line(
                "CANDIDATES edited clips with a cloud-only rendering, both resources under 60 MB: \(candidates.count)")
            // Larger ones first: a 4K clip is the likelier Dolby Vision source.
            let sorted = candidates.sorted { ($0.fullSizeSize ?? 0) > ($1.fullSizeSize ?? 0) }
            guard let pick = sorted.first,
                let asset = PHAsset.fetchAssets(withLocalIdentifiers: [pick.id], options: nil).firstObject
            else {
                log.line("RESULT no small cloud-only edited clip")
                return
            }
            let resources = PHAssetResource.assetResources(for: asset)
            log.line(
                "CLOUD edited resources: \(resources.map { resourceTypeName($0.type) }.joined(separator: ", ")); "
                    + ".fullSizeVideo \(pick.fullSizeSize ?? 0) bytes, .video \(pick.videoSize ?? 0) bytes")
            // Without network access the export session must not download anything.
            await exportSession(for: asset, label: "cloud-offline", network: false)

            guard let original = resources.first(where: { $0.type == .video }),
                let rendering = resources.first(where: { $0.type == .fullSizeVideo })
            else { return }
            let originalURL = tempFolder.appending(path: "cloud-original.mov")
            var started = Date()
            try await write(original, to: originalURL)
            log.line(
                "WRITE cloud edited .video downloaded in \(seconds(since: started)), \(fileSize(originalURL)) bytes")
            log.inventory(
                "INVENTORY cloud-edited-original (.video)", try await MediaInspector().inventory(of: originalURL))

            let renderingURL = tempFolder.appending(path: "cloud-fullsize.mov")
            started = Date()
            try await write(rendering, to: renderingURL)
            log.line(
                "WRITE cloud edited .fullSizeVideo downloaded in \(seconds(since: started)), \(fileSize(renderingURL)) bytes"
            )
            log.inventory(
                "INVENTORY cloud-edited-fullSizeVideo", try await MediaInspector().inventory(of: renderingURL))
            await compare("cloud edited .video -> .fullSizeVideo", originalURL, renderingURL)

            await exportSession(for: asset, label: "cloud-online", network: true, compareTo: originalURL)
        }
    }
#endif
