import AVFoundation
import AarikCore
import CoreMedia
import Foundation

/// Reads `video.*`, `hdr.*`, `audio.<n>.*`, `timed.*` and `track.<n>.kind` items, in track order.
enum TrackInspector {
    private static let dolbyVisionAtoms = ["dvcC", "dvvC", "dvwC"]

    static func items(of asset: AVAsset) async throws -> [MetadataItem] {
        let tracks = try await asset.load(.tracks)
        var primaryVideoID: CMPersistentTrackID?
        for track in tracks where track.mediaType == .video {
            if try await track.load(.isEnabled) {
                primaryVideoID = track.trackID
                break
            }
        }

        var result: [MetadataItem] = []
        var audioIndex = 0
        var timedIdentifiers = Set<String>()
        for (index, track) in tracks.enumerated() {
            let descriptions = try await track.load(.formatDescriptions)
            let timedIDs = track.mediaType == .metadata ? metadataIdentifiers(descriptions) : []
            if track.trackID == primaryVideoID {
                result += try await videoItems(track, description: descriptions.first)
            } else if track.mediaType == .audio {
                result += audioItems(index: audioIndex, description: descriptions.first)
                audioIndex += 1
            } else if !timedIDs.isEmpty {
                for id in timedIDs where timedIdentifiers.insert(id).inserted {
                    result.append(
                        MetadataItem(
                            key: "timed.\(id)", category: .timedMetadata,
                            displayName: "Timed metadata \(id)", value: "present"))
                }
            } else {
                let subtype = descriptions.first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "none"
                result.append(
                    MetadataItem(
                        key: "track.\(index).kind", category: .track,
                        displayName: "Track \(index + 1) kind", value: "\(track.mediaType.rawValue)/\(subtype)"))
            }
        }
        return result
    }

    // MARK: - Video

    private static func videoItems(_ track: AVAssetTrack, description: CMFormatDescription?) async throws
        -> [MetadataItem]
    {
        let (size, frameRate, transform) = try await track.load(
            .naturalSize, .nominalFrameRate, .preferredTransform)
        var items = [
            video("dimensions", "Dimensions", "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"),
            video("frameRate", "Frame rate", String(format: "%.2f", frameRate)),
            video(
                "transform", "Transform",
                [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty]
                    .map { String(Int($0.rounded())) }.joined(separator: ",")),
        ]
        guard let description else { return items }

        items.append(video("codec", "Codec", fourCC(CMFormatDescriptionGetMediaSubType(description))))
        let colorKeys: [(String, String, CFString)] = [
            ("colorPrimaries", "Color primaries", kCMFormatDescriptionExtension_ColorPrimaries),
            ("transferFunction", "Transfer function", kCMFormatDescriptionExtension_TransferFunction),
            ("matrix", "Color matrix", kCMFormatDescriptionExtension_YCbCrMatrix),
        ]
        for (key, name, ext) in colorKeys {
            if let value = CMFormatDescriptionGetExtension(description, extensionKey: ext) as? String {
                items.append(video(key, name, value))
            }
        }
        let atoms = sampleDescriptionAtoms(description)
        items.append(video("bitDepth", "Bit depth", bitDepth(description, atoms: atoms)))

        if let atom = dolbyVisionAtoms.lazy.compactMap({ atoms[$0] }).first {
            items.append(
                MetadataItem(
                    key: "hdr.dolbyVision", category: .hdr, displayName: "Dolby Vision",
                    value: DolbyVisionConfig(record: atom)?.displayValue ?? "present"))
        }
        if flag(description, kCMFormatDescriptionExtension_HasLeftStereoEyeView),
            flag(description, kCMFormatDescriptionExtension_HasRightStereoEyeView)
        {
            items.append(
                MetadataItem(key: "hdr.stereo", category: .hdr, displayName: "Stereo views", value: "left+right"))
        }
        return items
    }

    private static func video(_ key: String, _ name: String, _ value: String) -> MetadataItem {
        MetadataItem(key: "video.\(key)", category: .video, displayName: name, value: value)
    }

    /// HEVC: `bitDepthLumaMinus8` from the `hvcC` record; otherwise BitsPerComponent; otherwise 8.
    private static func bitDepth(_ description: CMFormatDescription, atoms: [String: Data]) -> String {
        if let hvcC = atoms["hvcC"], hvcC.count > 17 {
            return String(Int(hvcC[hvcC.startIndex + 17] & 0x07) + 8)
        }
        if let bits = CMFormatDescriptionGetExtension(
            description, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? Int
        {
            return String(bits)
        }
        return "8"
    }

    /// Atom name → body. An atom stored as an array of bodies yields its first.
    private static func sampleDescriptionAtoms(_ description: CMFormatDescription) -> [String: Data] {
        guard
            let atoms = CMFormatDescriptionGetExtension(
                description, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms)
                as? [String: Any]
        else { return [:] }
        return atoms.compactMapValues { ($0 as? Data) ?? ($0 as? [Data])?.first }
    }

    private static func flag(_ description: CMFormatDescription, _ key: CFString) -> Bool {
        CMFormatDescriptionGetExtension(description, extensionKey: key) as? Bool ?? false
    }

    // MARK: - Audio and timed metadata

    private static func audioItems(index: Int, description: CMFormatDescription?) -> [MetadataItem] {
        guard let description, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
        else { return [] }
        func audio(_ key: String, _ name: String, _ value: String) -> MetadataItem {
            MetadataItem(
                key: "audio.\(index).\(key)", category: .audio, displayName: "Audio track \(index + 1) \(name)",
                value: value)
        }
        return [
            audio("format", "format", fourCC(asbd.mFormatID)),
            audio("channels", "channels", String(asbd.mChannelsPerFrame)),
            audio("sampleRate", "sample rate", String(Int(asbd.mSampleRate.rounded()))),
        ]
    }

    private static func metadataIdentifiers(_ descriptions: [CMFormatDescription]) -> [String] {
        descriptions.flatMap { CMMetadataFormatDescriptionGetIdentifiers($0) as? [String] ?? [] }
    }
}
