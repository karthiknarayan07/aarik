import AVFoundation
import AppCore
import CoreMedia
import Foundation

/// Reads `video.*`, `hdr.*`, `audio.<n>.*`, `timed.*`, `track.<n>.kind` and `trackmeta.<n>.*` items, in track order.
enum TrackInspector {
    private static let dolbyVisionAtoms = ["dvcC", "dvvC", "dvwC"]
    /// Sample description atoms that mark a multiview (MV-HEVC, spatial) stream.
    private static let stereoAtoms = ["lhvC", "vexu"]
    /// Static HDR metadata: key, display name, format description extension.
    private static var staticHDRKeys: [(String, String, CFString)] {
        [
            ("masteringDisplay", "Mastering display", kCMFormatDescriptionExtension_MasteringDisplayColorVolume),
            ("contentLightLevel", "Content light level", kCMFormatDescriptionExtension_ContentLightLevelInfo),
            (
                "ambientViewingEnvironment", "Ambient viewing environment",
                kCMFormatDescriptionExtension_AmbientViewingEnvironment
            ),
        ]
    }

    static func items(of asset: AVAsset) async throws -> [MetadataItem] {
        let tracks = try await asset.load(.tracks)
        var primaryVideoID: CMPersistentTrackID?
        for track in tracks where track.mediaType == .video {
            if try await track.load(.isEnabled) {
                primaryVideoID = track.trackID
                break
            }
        }
        var audioIndexByID: [CMPersistentTrackID: Int] = [:]
        for track in tracks where track.mediaType == .audio { audioIndexByID[track.trackID] = audioIndexByID.count }
        /// How another track is named in an audio item's value: `audio <n>`, or `track <index>` for other kinds.
        func name(of trackID: CMPersistentTrackID) -> String {
            if let audio = audioIndexByID[trackID] { return "audio \(audio)" }
            return "track \(tracks.firstIndex { $0.trackID == trackID } ?? -1)"
        }
        let groups = try await asset.load(.trackGroups)

        var result: [MetadataItem] = []
        var timedIdentifiers = Set<String>()
        for (index, track) in tracks.enumerated() {
            let descriptions = try await track.load(.formatDescriptions)
            let timedIDs = track.mediaType == .metadata ? metadataIdentifiers(descriptions) : []
            if track.trackID == primaryVideoID {
                result += try await videoTrackItems(track)
                if let description = descriptions.first { result += formatItems(description) }
            } else if let audioIndex = audioIndexByID[track.trackID] {
                let group = groups.first { $0.trackIDs.contains(NSNumber(value: track.trackID)) }
                let fallback = try await track.loadAssociatedTracks(ofType: .audioFallback)
                result += audioItems(
                    index: audioIndex, description: descriptions.first,
                    duration: try await durationMilliseconds(track),
                    isEnabled: try await track.load(.isEnabled),
                    alternateGroup: group.map { $0.trackIDs.map { name(of: $0.int32Value) }.joined(separator: ", ") }
                        ?? "none",
                    fallback: fallback.isEmpty ? "none" : fallback.map { name(of: $0.trackID) }.joined(separator: ", "))
            } else if !timedIDs.isEmpty {
                let duration = try await durationMilliseconds(track)
                for id in timedIDs where timedIdentifiers.insert(id).inserted {
                    result.append(
                        MetadataItem(
                            key: "timed.\(id)", category: .timedMetadata,
                            displayName: "Timed metadata \(id)", value: "present"))
                    result.append(
                        MetadataItem(
                            key: "timed.\(id).duration", category: .timedMetadata,
                            displayName: "Timed metadata \(id) duration", value: duration))
                }
            } else {
                let subtype = descriptions.first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "none"
                result.append(
                    MetadataItem(
                        key: "track.\(index).kind", category: .track,
                        displayName: "Track \(index + 1) kind", value: "\(track.mediaType.rawValue)/\(subtype)"))
            }
            result += try await AssetMetadataReader.trackItems(of: track, trackIndex: index)
        }
        return result
    }

    /// The track's duration in whole milliseconds, so a cut-short track shows up as changed.
    private static func durationMilliseconds(_ track: AVAssetTrack) async throws -> String {
        let seconds = try await track.load(.timeRange).duration.seconds
        return seconds.isFinite ? String(Int((seconds * 1000).rounded())) : "unknown"
    }

    // MARK: - Video

    private static func videoTrackItems(_ track: AVAssetTrack) async throws -> [MetadataItem] {
        let (size, frameRate, transform) = try await track.load(
            .naturalSize, .nominalFrameRate, .preferredTransform)
        return [
            video("dimensions", "Dimensions", "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"),
            video("frameRate", "Frame rate", String(format: "%.2f", frameRate)),
            video(
                "transform", "Transform",
                [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty]
                    .map { String(Int($0.rounded())) }.joined(separator: ",")),
            video("duration", "Duration (ms)", try await durationMilliseconds(track)),
        ]
    }

    /// Codec, color, bit depth and `hdr.*` items from the primary video track's format description.
    static func formatItems(_ description: CMFormatDescription) -> [MetadataItem] {
        var items = [video("codec", "Codec", fourCC(CMFormatDescriptionGetMediaSubType(description)))]
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
        for (key, name, ext) in staticHDRKeys {
            if let data = CMFormatDescriptionGetExtension(description, extensionKey: ext) as? Data {
                items.append(MetadataItem(key: "hdr.\(key)", category: .hdr, displayName: name, value: hex(data)))
            }
        }
        if flag(description, kCMFormatDescriptionExtension_HasLeftStereoEyeView),
            flag(description, kCMFormatDescriptionExtension_HasRightStereoEyeView)
        {
            items.append(
                MetadataItem(key: "hdr.stereo", category: .hdr, displayName: "Stereo views", value: "left+right"))
        } else if let atom = stereoAtoms.first(where: { atoms[$0] != nil }) {
            items.append(
                MetadataItem(
                    key: "hdr.stereo", category: .hdr, displayName: "Stereo views", value: "multiview (\(atom))"))
        }
        return items
    }

    private static func video(_ key: String, _ name: String, _ value: String) -> MetadataItem {
        MetadataItem(key: "video.\(key)", category: .video, displayName: name, value: value)
    }

    /// HEVC: `bitDepthLumaMinus8` from the `hvcC` record. H.264: 8 for the profiles that only allow 8 bits
    /// (Baseline, Main, Extended, High), else the `avcC` high-profile extension. Otherwise BitsPerComponent.
    /// `"unknown"` when none of these says, so the encoder keeps 10 bits rather than guess 8.
    private static func bitDepth(_ description: CMFormatDescription, atoms: [String: Data]) -> String {
        if let hvcC = atoms["hvcC"], hvcC.count > 17 {
            return String(Int(hvcC[hvcC.startIndex + 17] & 0x07) + 8)
        }
        if let avcC = atoms["avcC"], let depth = avcBitDepth(avcC) { return String(depth) }
        if let bits = CMFormatDescriptionGetExtension(
            description, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? Int
        {
            return String(bits)
        }
        return "unknown"
    }

    /// Luma bit depth from an `avcC` record (ISO/IEC 14496-15 5.3.3.1.2), or nil if it doesn't say.
    private static func avcBitDepth(_ avcC: Data) -> Int? {
        let bytes = [UInt8](avcC)
        guard bytes.count > 5 else { return nil }
        let profile = bytes[1]
        if [66, 77, 88, 100].contains(profile) { return 8 }
        // Skip the SPS and PPS lists to reach the extension (chroma_format, bit_depth_luma_minus8, ...).
        var offset = 6
        func skipParameterSets(count: Int) -> Bool {
            for _ in 0..<count {
                guard offset + 2 <= bytes.count else { return false }
                offset += 2 + (Int(bytes[offset]) << 8 | Int(bytes[offset + 1]))
            }
            return offset <= bytes.count
        }
        guard skipParameterSets(count: Int(bytes[5] & 0x1F)), offset < bytes.count else { return nil }
        let ppsCount = Int(bytes[offset])
        offset += 1
        guard skipParameterSets(count: ppsCount), offset + 1 < bytes.count else { return nil }
        return Int(bytes[offset + 1] & 0x07) + 8
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

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Audio and timed metadata

    private static func audioItems(
        index: Int, description: CMFormatDescription?, duration: String, isEnabled: Bool, alternateGroup: String,
        fallback: String
    ) -> [MetadataItem] {
        func audio(_ key: String, _ name: String, _ value: String) -> MetadataItem {
            MetadataItem(
                key: "audio.\(index).\(key)", category: .audio, displayName: "Audio track \(index + 1) \(name)",
                value: value)
        }
        var items: [MetadataItem] = []
        if let description, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
            items += [
                audio("format", "format", fourCC(asbd.mFormatID)),
                audio("channels", "channels", String(asbd.mChannelsPerFrame)),
                audio("sampleRate", "sample rate", String(Int(asbd.mSampleRate.rounded()))),
            ]
        }
        return items + [
            audio("duration", "duration (ms)", duration),
            audio("enabled", "enabled", isEnabled ? "true" : "false"),
            audio("alternateGroup", "alternate group", alternateGroup),
            audio("fallback", "fallback", fallback),
        ]
    }

    private static func metadataIdentifiers(_ descriptions: [CMFormatDescription]) -> [String] {
        descriptions.flatMap { CMMetadataFormatDescriptionGetIdentifiers($0) as? [String] ?? [] }
    }
}
