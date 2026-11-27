import Assistant
import AppCore
import Foundation

/// The sentence the model reads for each reason code. The runners write reasons, warnings and notes as plain text
/// that can carry a file name, a folder, a place or a value, so none of that text goes to the model: a result
/// carries a code beside each text (`OutcomeCode`), and the model is given the code's own sentence. A result saved
/// before codes existed reads as `.other`, which carries no detail at all.
extension OutcomeCode {
    /// The plain sentence the model reads for this code. Written here, never taken from the result.
    var sentence: String {
        switch self {
        case .alreadySmall: "The video was already small, so converting would not help."
        case .savesLittle: "Converting would save less than ten percent, so the video was left as it is."
        case .spatialVideo: "Spatial video is not supported yet; converting it would lose one eye's view."
        case .lengthUnreadable: "The length of the video could not be read."
        case .formatCannotKeepDetails: "The video's file format cannot keep all of its details."
        case .lossNotShownBeforeAdding:
            "Converting would lose details that were not known when the video was added to the queue."
        case .unsupportedVideo: "This kind of video cannot be converted yet."
        case .unsupportedImage: "This kind of image cannot be converted yet."
        case .conversionFailed: "The conversion failed."
        case .originalUnavailable: "The original video or the drive holding it was not available."
        case .outputFolderUnavailable: "The chosen output folder or its drive was not available."
        case .notEnoughSpace: "There was not enough free space on this Mac."
        case .outputNameTaken: "No free name for the new file could be found."
        case .iCloudDownloadFailed: "The video could not be downloaded from iCloud."
        case .photosAccessDenied: "Access to the Photos library is not allowed."
        case .photosSaveFailed: "The new video could not be saved to Photos or did not check out."
        case .noToolForJob: "No tool could run this job."
        case .cancelled: "The conversion was cancelled."
        case .unexpectedLoss: "Something was lost that was not predicted when the video was added."
        case .unexpectedChange: "Something changed that was not expected to."
        case .originalChangedDuringConversion: "The original changed while it was being converted."
        case .originalKeptBackupFailed: "The original was kept because its backup could not be made."
        case .originalKeptCouldNotTrash: "The original was kept because it could not be moved to the Trash."
        case .originalKeptNotVerified: "The original was kept because the new copy could not be verified."
        case .originalKeptOtherReason: "The original was kept."
        case .notAddedToAlbums: "The new video could not be added to the original's albums."
        case .containerChanged: "The new file uses another file format because the original's cannot hold all tracks."
        case .nameChanged: "The new file has a different name than planned because the planned name was taken."
        case .savedToPhotos: "The new video was saved to Photos."
        case .originalInRecentlyDeleted: "The original goes to or is in Recently Deleted."
        case .originalGone: "The original was no longer in Photos."
        case .other: "Another detail the app cannot describe."
        }
    }
}

/// Plain names for metadata items that are safe to send: only names the app itself defines. A name that comes
/// from the file (an extended attribute, an unknown tag) is replaced by a generic one, so nothing the user or a
/// camera wrote can reach the model.
enum PromptMetadataNames {
    /// Names the metadata reader gives fixed keys; anything else under `qt.` is not one of these.
    private static let knownQuickTimeNames: Set<String> = [
        "Camera make", "Camera model", "Software", "Lens model", "Location", "Creation date",
        "Live Photo identifier",
    ]

    /// One safe name per item, each once, in order.
    static func names(of items: [MetadataItem], context: [MetadataItem] = []) -> [String] {
        let auxiliary = MetadataNames.auxiliaryTracks(in: items + context)
        var seen = Set<String>()
        return items.map { name(key: $0.key, displayName: $0.displayName, auxiliaryTracks: auxiliary) }
            .filter { seen.insert($0).inserted }
    }

    static func names(of changes: [MetadataChange], context: [MetadataItem] = []) -> [String] {
        let auxiliary = MetadataNames.auxiliaryTracks(in: context)
        var seen = Set<String>()
        return changes.map { name(key: $0.key, displayName: $0.displayName, auxiliaryTracks: auxiliary) }
            .filter { seen.insert($0).inserted }
    }

    /// For the names the planner recorded when the job was added: with their keys when the two lists line up,
    /// else only names that are in the fixed set. Names that can't be vouched for count as "Other metadata".
    static func names(predicted names: [String], keys: [String]?) -> [String] {
        let safe: [String]
        if let keys, keys.count == names.count {
            safe = zip(keys, names).map { name(key: $0, displayName: $1, auxiliaryTracks: []) }
        } else {
            let known = knownQuickTimeNames.union(MetadataNames.isoUserData.values.map(\.name)).union(fixedNames)
            safe = names.map { known.contains($0) ? $0 : "Other metadata" }
        }
        var seen = Set<String>()
        return safe.filter { seen.insert($0).inserted }
    }

    /// Names the inspector gives its own fixed keys.
    private static let fixedNames: Set<String> = [
        "Finder tags", "File creation date", "Stereo views", "Dolby Vision", MetadataNames.cinematicDepth,
    ]

    static func name(key: String, displayName: String, auxiliaryTracks: Set<Int>) -> String {
        let plain = MetadataNames.plainName(key: key, displayName: displayName, auxiliaryTracks: auxiliaryTracks)
        if key.hasPrefix("fs.xattr.") { return "Extended attribute" }
        if key.hasPrefix("video.") || key.hasPrefix("hdr.") || key == "fs.tags" || key == "fs.creationDate" {
            return plain
        }
        if key.hasPrefix("timed.") { return plain }
        if MetadataNames.isoUserDataName(forKey: key) != nil { return plain }
        if plain == MetadataNames.cinematicDepth { return plain }
        if key.hasPrefix("qt."), knownQuickTimeNames.contains(plain) { return plain }
        if key.hasPrefix("track."), key.hasSuffix(".kind") { return plain }
        return "Other metadata"
    }
}
