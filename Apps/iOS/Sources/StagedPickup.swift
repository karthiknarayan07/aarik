import AppCore
import AppServices
import Convert
import Foundation

/// Options or library selection filters passed from `ShrinkVideosIntent` when opening the iOS app.
public struct IntentHandoffOptions: Sendable, Equatable {
    public var preset: Preset?
    public var qualityName: String?
    public var formatName: String?
    public var destinationName: String?
    public var folderURL: URL?
    public var dateRangeName: String?
    public var resolutionName: String?
    public var sourceName: String?
    public var waitForCompletion: Bool

    public init(
        preset: Preset? = nil, qualityName: String? = nil, formatName: String? = nil,
        destinationName: String? = nil, folderURL: URL? = nil, dateRangeName: String? = nil,
        resolutionName: String? = nil, sourceName: String? = nil, waitForCompletion: Bool = true
    ) {
        self.preset = preset
        self.qualityName = qualityName
        self.formatName = formatName
        self.destinationName = destinationName
        self.folderURL = folderURL
        self.dateRangeName = dateRangeName
        self.resolutionName = resolutionName
        self.sourceName = sourceName
        self.waitForCompletion = waitForCompletion
    }
}

/// Coordinates staged inputs between the Share Extension, `ShrinkVideosIntent`, and the iOS app shell.
///
/// Both the Share Extension and `ShrinkVideosIntent` stream-copy inputs into the shared App Group `Staging/<uuid>/`
/// directory via `StagedInputs`. On app activation (`scenePhase == .active`) or when `didStageNotification` fires,
/// the shell calls `StagedPickup` to pick up newly staged files as `[MediaInput]` and deliver them to the active
/// `IOSToolScene`.
@MainActor
public final class StagedPickup {
    public static let shared = StagedPickup()
    public static let didStageNotification = Notification.Name("StagedPickupDidStage")

    /// Pending options from the most recent `ShrinkVideosIntent` invocation, consumed by the shell when ready.
    public private(set) var pendingOptions: IntentHandoffOptions?

    private var deliveredCanonicalPaths: Set<String> = []

    public init() {}

    /// Resolves the shared App Group `StagedInputs` store, falling back to the app's Application Support staging
    /// directory if the App Group container is unavailable.
    public nonisolated static func stagingStore(
        bundle: Bundle = .main,
        fallbackSupportDirectory: URL? = nil
    ) -> StagedInputs {
        let fallback =
            fallbackSupportDirectory
            ?? AppServices.supportDirectory(bundleIdentifier: bundle.bundleIdentifier)
        return StagedInputs.appGroup(in: bundle, fallbackDirectory: fallback)
            ?? StagedInputs(
                directory: fallback.appending(path: AppServices.stagingFolderName, directoryHint: .isDirectory))
    }

    /// Records intent options and posts `didStageNotification` so an already-active shell picks up immediately.
    public func recordIntentHandoff(options: IntentHandoffOptions?) {
        if let options { pendingOptions = options }
        NotificationCenter.default.post(name: Self.didStageNotification, object: self)
    }

    /// Returns and clears any pending intent hand-off options.
    public func consumePendingOptions() -> IntentHandoffOptions? {
        defer { pendingOptions = nil }
        return pendingOptions
    }

    /// Scans the staging directory off the main actor for newly staged files not already in `services.jobs` or
    /// previously delivered in this session, watches them in `services`, and delivers them to `scene.receive(_:)`.
    @discardableResult
    public func pickUp<Scene: IOSToolScene>(
        into scene: Scene,
        services: AppServices,
        store: StagedInputs = stagingStore()
    ) async -> [URL] {
        let existingSources = Set(services.jobs.map(\.source))
        let alreadyDelivered = deliveredCanonicalPaths
        let pending = await Task.detached(priority: .userInitiated) {
            store.pendingFiles(excluding: existingSources).filter { url in
                !alreadyDelivered.contains(url.standardizedFileURL.resolvingSymlinksInPath().path)
            }
        }.value

        guard !pending.isEmpty else { return [] }

        for url in pending {
            deliveredCanonicalPaths.insert(url.standardizedFileURL.resolvingSymlinksInPath().path)
        }
        services.watchStaged(pending)
        scene.receive(pending.map(MediaInput.file))
        return pending
    }

    /// Resets in-session delivery tracking (for example, in tests).
    public func resetDelivered() {
        deliveredCanonicalPaths.removeAll()
        pendingOptions = nil
    }
}
