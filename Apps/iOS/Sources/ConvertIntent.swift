import AppCore
import AppIntents
import Convert
import Foundation
import UniformTypeIdentifiers

/// The Shrink Videos action on iOS: in Shortcuts, by Siri, and in Spotlight. Uses `supportedModes = .foreground`
/// (iOS 26) so the app opens before `perform()`, stages handed-in videos via `StagedInputs` off the main actor,
/// and hands off to the app shell on activation. Never encodes inside an extension.
struct ShrinkVideosIntent: AppIntent {
    static let title: LocalizedStringResource = "Shrink Videos"
    static let description = IntentDescription(
        """
        Shrinks videos to 1080p and keeps their metadata. Videos you give the action win over the date range, \
        resolution and source.
        """,
        categoryName: "Videos",
        searchKeywords: ["shrink", "compress", "smaller", "downscale", "1080p", "4K", "video"])
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Media", description: "The videos or images to shrink.", supportedContentTypes: [.movie, .image])
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
        let given = files ?? []
        let hasSelection = dateRange != nil || resolution != nil || source != nil
        if given.isEmpty, !hasSelection {
            throw $files.needsValueError("Which videos do you want to shrink?")
        }

        let store = StagedPickup.stagingStore()
        var stagingCandidates: [StagingCandidate] = []
        var skippedNonVideos = 0

        for file in given {
            if let type = file.type, !(type.conforms(to: .movie) || type.conforms(to: .image)) {
                skippedNonVideos += 1
                continue
            }
            if let url = file.fileURL {
                stagingCandidates.append(.url(url, filename: file.filename, hasExplicitMovieType: file.type != nil))
            } else if !file.data.isEmpty {
                stagingCandidates.append(.data(file.data, filename: file.filename))
            } else {
                skippedNonVideos += 1
            }
        }

        let stagingOutcome = await Task.detached(priority: .userInitiated) {
            Self.stage(candidates: stagingCandidates, into: store)
        }.value

        let totalSkipped = skippedNonVideos + stagingOutcome.skippedNonVideos
        if !given.isEmpty, stagingOutcome.staged.isEmpty {
            if totalSkipped > 0, stagingOutcome.failed == 0 {
                let message =
                    "No videos were added. Skipped \(totalSkipped) non-video \(totalSkipped == 1 ? "item" : "items")."
                return .result(value: [], dialog: IntentDialog(Self.resource(message)))
            }
            throw ShrinkVideosIntentError(message: "The videos you gave couldn't be read.")
        }

        let options = IntentHandoffOptions(
            preset: quality?.preset,
            qualityName: quality?.rawValue,
            formatName: format?.rawValue,
            destinationName: destination?.rawValue,
            folderURL: folder?.fileURL,
            dateRangeName: dateRange?.rawValue,
            resolutionName: resolution?.rawValue,
            sourceName: source?.rawValue,
            waitForCompletion: waitForCompletion)
        StagedPickup.shared.recordIntentHandoff(options: options)

        let message = Self.dialogMessage(
            stagedCount: stagingOutcome.staged.count,
            skippedNonVideos: totalSkipped,
            failed: stagingOutcome.failed,
            hasSelection: hasSelection,
            appName: AppInfo.displayName)
        return .result(value: [], dialog: IntentDialog(Self.resource(message)))
    }

    private enum StagingCandidate: Sendable {
        case url(URL, filename: String, hasExplicitMovieType: Bool)
        case data(Data, filename: String)
    }

    private struct StagingOutcome: Sendable {
        let staged: [URL]
        let skippedNonVideos: Int
        let failed: Int
    }

    private nonisolated static func stage(
        candidates: [StagingCandidate], into store: StagedInputs
    ) -> StagingOutcome {
        var staged: [URL] = []
        var skippedNonVideos = 0
        var failed = 0
        for candidate in candidates {
            switch candidate {
            case .url(let url, let filename, let hasExplicitMovieType):
                if StagedInputs.isSymbolicLink(url) {
                    failed += 1
                    continue
                }
                if !hasExplicitMovieType, !StagedInputs.isMediaFile(url) {
                    skippedNonVideos += 1
                    continue
                }
                do {
                    try staged.append(store.stage(copying: url, name: filename))
                } catch {
                    failed += 1
                }
            case .data(let data, let filename):
                do {
                    try staged.append(store.stage(name: filename, data: data))
                } catch {
                    failed += 1
                }
            }
        }
        return StagingOutcome(staged: staged, skippedNonVideos: skippedNonVideos, failed: failed)
    }

    private static func dialogMessage(
        stagedCount: Int, skippedNonVideos: Int, failed: Int, hasSelection: Bool, appName: String
    ) -> String {
        if stagedCount > 0 {
            let label = stagedCount == 1 ? "1 video" : "\(stagedCount) videos"
            var parts = ["Added \(label) to \(appName)."]
            if skippedNonVideos > 0 {
                parts.append(
                    skippedNonVideos == 1
                        ? "1 non-video item was skipped." : "\(skippedNonVideos) non-video items were skipped.")
            }
            if failed > 0 {
                parts.append("\(failed) couldn't be read.")
            }
            return parts.joined(separator: " ")
        }
        if hasSelection {
            return "Opened \(appName) to review matching videos."
        }
        return "Opened \(appName)."
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

// MARK: - Choices

enum ShrinkQualityOption: String, AppEnum {
    case high, balanced, smaller

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Quality"
    static let caseDisplayRepresentations: [ShrinkQualityOption: DisplayRepresentation] = [
        .high: DisplayRepresentation(title: "High", subtitle: "Keeps the resolution"),
        .balanced: DisplayRepresentation(title: "Balanced", subtitle: "1080p"),
        .smaller: DisplayRepresentation(title: "Smaller", subtitle: "1080p, a lower bit rate"),
    ]

    var preset: Preset {
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
}

enum ShrinkDestinationOption: String, AppEnum {
    case nextToOriginal, folder

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Destination"
    static let caseDisplayRepresentations: [ShrinkDestinationOption: DisplayRepresentation] = [
        .nextToOriginal: "Next to Original",
        .folder: "Folder",
    ]
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
}

enum ShrinkResolutionOption: String, AppEnum {
    case uhd, fullHD

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Resolution"
    static let caseDisplayRepresentations: [ShrinkResolutionOption: DisplayRepresentation] = [
        .uhd: "4K",
        .fullHD: "1080p",
    ]
}

enum ShrinkSourceOption: String, AppEnum {
    case localFiles, photos

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Source"
    static let caseDisplayRepresentations: [ShrinkSourceOption: DisplayRepresentation] = [
        .localFiles: "Local Files",
        .photos: "Photos",
    ]
}

// MARK: - Siri and Spotlight

/// The phrases Siri understands and the tiles Spotlight and Shortcuts offer. Each phrase has the app's name in it,
/// as the system requires.
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
