import Foundation

/// Why a job ended as it did, as a closed set that is saved with the result. The runners write a plain sentence
/// for the person and a code for the app: the sentence can carry a file name, a folder or a value and changes with
/// the wording, while the code never does, so anything that has to tell reasons apart (the Assistant's explanation,
/// a count by reason) reads the code and never matches text.
///
/// A code this version doesn't know (written by a newer one) or a result saved before codes existed reads as
/// `.other`.
public enum OutcomeCode: String, Codable, Sendable, CaseIterable {
    // Why a video was kept as it is, or failed.
    case alreadySmall
    case savesLittle
    case spatialVideo
    case lengthUnreadable
    case formatCannotKeepDetails
    case lossNotShownBeforeAdding
    case unsupportedVideo
    case unsupportedImage
    case conversionFailed
    case originalUnavailable
    case outputFolderUnavailable
    case notEnoughSpace
    case outputNameTaken
    case iCloudDownloadFailed
    case photosAccessDenied
    case photosSaveFailed
    case noToolForJob
    case cancelled
    // Warnings.
    case unexpectedLoss
    case unexpectedChange
    case originalChangedDuringConversion
    case originalKeptBackupFailed
    case originalKeptCouldNotTrash
    case originalKeptNotVerified
    case originalKeptOtherReason
    case notAddedToAlbums
    // Notes.
    case containerChanged
    case nameChanged
    case savedToPhotos
    case originalInRecentlyDeleted
    case originalGone
    /// Anything else, and the reading of a code this version doesn't know.
    case other

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = OutcomeCode(rawValue: raw) ?? .other
    }
}

/// A sentence for the person and the code for the app, written together so they can't disagree.
public struct OutcomeLine: Sendable, Equatable {
    public let text: String
    public let code: OutcomeCode

    public init(_ text: String, _ code: OutcomeCode) {
        self.text = text
        self.code = code
    }
}

/// An error that knows its own code. The queue records it with the error's sentence when a run throws one.
public protocol OutcomeCoded: Error {
    var outcomeCode: OutcomeCode { get }
}
