import AppIntents
import Foundation
import QuickRunService
import UniformTypeIdentifiers

/// The Shrink Videos action: in Shortcuts, as a Finder Quick Action (Shortcuts › the action › Use as Quick Action ›
/// Finder), by Siri and in Spotlight. It is a quick run (`QuickRun`): the saved defaults unless a parameter says
/// otherwise, never Replace, files that would lose metadata are skipped, and one notification per run.
///
/// Videos handed in (`files`) win. With none, the date range, resolution and source pick videos from the app's own
/// libraries with the same filters as the grid. It never uses the language model, so it is always available.
struct ShrinkVideosIntent: AppIntent {
    static let title: LocalizedStringResource = "Shrink Videos"
    static let description = IntentDescription(
        """
        Shrinks videos to 1080p and keeps their metadata. Nothing is replaced, and videos that would lose metadata \
        are skipped. Videos you give the action win over the date range, resolution and source.
        """,
        categoryName: "Videos",
        searchKeywords: ["shrink", "compress", "smaller", "downscale", "1080p", "4K", "video"])
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Videos", description: "The videos to shrink.", supportedContentTypes: [.movie])
    var files: [IntentFile]?

    @Parameter(
        title: "Quality", description: "How hard to shrink. Without a choice, the app's default is used.")
    var quality: ShrinkQualityOption?

    @Parameter(title: "Format", description: "The video format to write. Without a choice, HEVC is used.")
    var format: ShrinkFormatOption?

    @Parameter(
        title: "Destination",
        description: "Where the smaller videos go. Without a choice, the app's default is used (never Replace).")
    var destination: ShrinkDestinationOption?

    @Parameter(
        title: "Folder", description: "The folder to save in when the destination is Folder.",
        supportedContentTypes: [.folder])
    var folder: IntentFile?

    @Parameter(
        title: "Wait for Completion",
        description: "Return the smaller videos when they are done. Turn off to return right away.",
        default: true)
    var waitForCompletion: Bool

    @Parameter(
        title: "Date Range",
        description: "Used when no videos are given: only videos captured in this period.")
    var dateRange: ShrinkDateRangeOption?

    @Parameter(
        title: "Resolution", description: "Used when no videos are given: only videos with this resolution.")
    var resolution: ShrinkResolutionOption?

    @Parameter(
        title: "Source",
        description: "Used when no videos are given: where to pick videos from. Local Files is the default.")
    var source: ShrinkSourceOption?

    static var parameterSummary: some ParameterSummary {
        Summary(
            "Shrink \(\.$files), or if there are none, \(\.$resolution) videos from \(\.$dateRange) in \(\.$source)"
        ) {
            \.$quality
            \.$format
            \.$destination
            \.$folder
            \.$waitForCompletion
        }
    }

    init() {}

    /// For the App Shortcuts that pick videos by a date range or a resolution.
    init(dateRange: ShrinkDateRangeOption? = nil, resolution: ShrinkResolutionOption? = nil) {
        self.dateRange = dateRange
        self.resolution = resolution
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> & ProvidesDialog {
        let request = ShrinkVideosRequest(
            files: (files ?? []).compactMap(IntentStaging.url(for:)), quality: quality?.choice,
            format: format?.choice, destination: destination?.choice, folder: folder.flatMap(IntentStaging.url(for:)),
            dateRange: dateRange?.choice, resolution: resolution?.choice, source: source?.choice,
            waitForCompletion: waitForCompletion)
        let outcome = await AppModel.shared.shrinkVideos(request)
        switch outcome {
        case .needsVideos:
            throw $files.needsValueError("Which videos do you want to shrink?")
        case .photosAccessNeeded, .failed:
            throw ShrinkVideosIntentError(message: outcome.message)
        case .nothingMatched:
            return .result(value: [], dialog: IntentDialog(Self.resource(outcome.message)))
        case .queued(_, let outputs):
            let files = (outputs ?? []).map { IntentFile(fileURL: $0, filename: $0.lastPathComponent) }
            return .result(value: files, dialog: IntentDialog(Self.resource(outcome.message)))
        }
    }

    private static func resource(_ text: String) -> LocalizedStringResource {
        LocalizedStringResource(String.LocalizationValue(text))
    }
}

/// A run that can't go ahead; Shortcuts and Siri show the message as it is.
struct ShrinkVideosIntentError: Error, CustomLocalizedStringResourceConvertible {
    let message: String

    var localizedStringResource: LocalizedStringResource {
        LocalizedStringResource(String.LocalizationValue(message))
    }
}

/// Where a file handed to an action is read: its own location when it has one, else a copy of its data in the
/// app's Staging folder (a video that came from Photos or another app as data only). The app isn't sandboxed, so a
/// location needs no security scope.
enum IntentStaging {
    static func url(for file: IntentFile) -> URL? {
        if let url = file.fileURL { return url }
        guard !file.data.isEmpty else { return nil }
        let directory = AppModel.supportDirectory().appending(
            path: "Staging/\(UUID().uuidString)", directoryHint: .isDirectory)
        let name = file.filename.isEmpty ? "Video.mov" : file.filename
        let url = directory.appending(path: name)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try file.data.write(to: url, options: .withoutOverwriting)
            return url
        } catch {
            return nil
        }
    }
}

// MARK: - Choices

enum ShrinkQualityOption: String, AppEnum {
    case high, balanced, smaller

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Quality"
    static let caseDisplayRepresentations: [ShrinkQualityOption: DisplayRepresentation] = [
        .high: DisplayRepresentation(title: "High", subtitle: "Keeps the resolution"),
        .balanced: DisplayRepresentation(title: "Balanced", subtitle: "1080p"),
        .smaller: DisplayRepresentation(title: "Smaller", subtitle: "1080p, a lower bit rate"),
    ]

    var choice: ShrinkQuality {
        switch self {
        case .high: .high
        case .balanced: .balanced
        case .smaller: .smaller
        }
    }
}

enum ShrinkFormatOption: String, AppEnum {
    case hevc, h264

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Format"
    static let caseDisplayRepresentations: [ShrinkFormatOption: DisplayRepresentation] = [
        .hevc: DisplayRepresentation(title: "HEVC", subtitle: "Keeps HDR"),
        .h264: DisplayRepresentation(title: "H.264", subtitle: "Plays everywhere, drops HDR"),
    ]

    var choice: ShrinkFormat {
        switch self {
        case .hevc: .hevc
        case .h264: .h264
        }
    }
}

enum ShrinkDestinationOption: String, AppEnum {
    case nextToOriginal, folder

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Destination"
    static let caseDisplayRepresentations: [ShrinkDestinationOption: DisplayRepresentation] = [
        .nextToOriginal: "Next to Original",
        .folder: "Folder",
    ]

    var choice: ShrinkDestination {
        switch self {
        case .nextToOriginal: .nextToOriginal
        case .folder: .folder
        }
    }
}

enum ShrinkDateRangeOption: String, AppEnum {
    case pastWeek, lastMonth, pastThreeMonths, thisYear, lastYear

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Date Range"
    static let caseDisplayRepresentations: [ShrinkDateRangeOption: DisplayRepresentation] = [
        .pastWeek: "Past Week",
        .lastMonth: "Last Month",
        .pastThreeMonths: "Past 3 Months",
        .thisYear: "This Year",
        .lastYear: "Last Year",
    ]

    var choice: ShrinkDateRange {
        switch self {
        case .pastWeek: .pastWeek
        case .lastMonth: .lastMonth
        case .pastThreeMonths: .pastThreeMonths
        case .thisYear: .thisYear
        case .lastYear: .lastYear
        }
    }
}

enum ShrinkResolutionOption: String, AppEnum {
    case uhd, fullHD

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Resolution"
    static let caseDisplayRepresentations: [ShrinkResolutionOption: DisplayRepresentation] = [
        .uhd: "4K",
        .fullHD: "1080p",
    ]

    var choice: ShrinkResolution {
        switch self {
        case .uhd: .uhd
        case .fullHD: .fullHD
        }
    }
}

enum ShrinkSourceOption: String, AppEnum {
    case localFiles, photos

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Source"
    static let caseDisplayRepresentations: [ShrinkSourceOption: DisplayRepresentation] = [
        .localFiles: "Local Files",
        .photos: "Photos",
    ]

    var choice: ShrinkSource {
        switch self {
        case .localFiles: .localFiles
        case .photos: .photos
        }
    }
}

// MARK: - Siri and Spotlight

/// The phrases Siri understands and the tiles Spotlight and Shortcuts offer. Each phrase has the app's name in it,
/// as the system requires. The ones that pick videos start the action with the choice already made.
struct ShrinkVideosShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ShrinkVideosIntent(),
            phrases: ["Shrink videos with \(.applicationName)"],
            shortTitle: "Shrink Videos", systemImageName: "film.stack")
        AppShortcut(
            intent: ShrinkVideosIntent(dateRange: .lastMonth),
            phrases: [
                "Shrink my videos from last month with \(.applicationName)",
                "Shrink last month's videos with \(.applicationName)",
            ],
            shortTitle: "Shrink Last Month's Videos", systemImageName: "calendar")
        AppShortcut(
            intent: ShrinkVideosIntent(resolution: .uhd),
            phrases: [
                "Shrink 4K videos with \(.applicationName)",
                "Shrink my 4K videos with \(.applicationName)",
            ],
            shortTitle: "Shrink 4K Videos", systemImageName: "4k.tv")
    }
}
