import AppCore
import Foundation

/// The Convert tool's stored settings. The Settings views bind them with `@AppStorage`; the model and the runner
/// read the same keys from `UserDefaults`. The queue's two shared keys (auto-start, speed) are `SettingsStore`'s.
public enum AppSettings {
    public enum Keys {
        public static let preset = "downscale.preset"
        public static let autoStartQueue = SettingsStore.Keys.autoStartQueue
        /// `SpeedSetting` raw value: quiet, balanced or fastest.
        public static let speed = SettingsStore.Keys.speed
        /// `SaveLocation.Choice` raw value: next to original or folder.
        public static let defaultSaveTo = "output.defaultSaveTo"
        public static let defaultSaveFolder = "output.defaultSaveFolder"
        public static let keepOriginals = "output.keepOriginals"
        /// A folder path; empty means the default folder.
        public static let originalsFolder = "output.originalsFolder"
    }

    /// `~/Movies/<App Name> Originals/`.
    public nonisolated static var defaultOriginalsFolder: URL {
        URL.moviesDirectory.appending(path: "\(AppInfo.displayName) Originals", directoryHint: .isDirectory)
    }

    public nonisolated static func originalsFolder(_ defaults: UserDefaults) -> URL {
        let path = defaults.string(forKey: Keys.originalsFolder) ?? ""
        return path.isEmpty ? defaultOriginalsFolder : URL(filePath: path, directoryHint: .isDirectory)
    }

    /// Read by the runner at each Replace, so turning the setting on or off applies to the next Replace.
    public nonisolated static func originalsBackup(_ defaults: UserDefaults) -> OriginalsBackup? {
        defaults.bool(forKey: Keys.keepOriginals) ? OriginalsBackup(folder: originalsFolder(defaults)) : nil
    }

    /// The runner's backup provider, reading `defaults` from the queue's executor.
    public nonisolated static func originalsBackupProvider(_ defaults: UserDefaults) -> ConvertRunner.BackupProvider {
        let shared = SharedDefaults(defaults)
        return { originalsBackup(shared.defaults) }
    }

    /// Creates the default originals folder. A folder the user picked is never created: if it is on a drive that
    /// isn't connected, creating it would put it on the startup disk instead.
    public static func prepareOriginalsFolder(_ defaults: UserDefaults) {
        guard (defaults.string(forKey: Keys.originalsFolder) ?? "").isEmpty else { return }
        try? FileManager.default.createDirectory(at: defaultOriginalsFolder, withIntermediateDirectories: true)
    }

    /// The Save to choice new selections start with: next to original, or a folder whose bookmark still resolves.
    public static func defaultSaveLocation(_ defaults: UserDefaults) -> SaveLocation {
        var location = SaveLocation()
        guard defaults.string(forKey: Keys.defaultSaveTo) == SaveLocation.Choice.folder.rawValue,
            let bookmark = defaults.data(forKey: Keys.defaultSaveFolder),
            let folder = resolve(bookmark)
        else { return location }
        location.choice = .folder
        location.folder = folder
        location.folderBookmark = bookmark
        return location
    }

    /// Never mounts a volume or shows UI: a folder on a disconnected drive just doesn't resolve.
    public static func resolve(_ bookmark: Data) -> URL? {
        var stale = false
        return
            (try? URL(
                resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutMounting, .withoutUI],
                relativeTo: nil, bookmarkDataIsStale: &stale))
            ?? (try? URL(
                resolvingBookmarkData: bookmark, options: [.withoutMounting, .withoutUI], relativeTo: nil,
                bookmarkDataIsStale: &stale))
    }
}

/// `UserDefaults` is documented as thread-safe but isn't marked `Sendable`; this lets the runner read it off the main
/// actor.
private struct SharedDefaults: @unchecked Sendable {
    let defaults: UserDefaults

    init(_ defaults: UserDefaults) {
        self.defaults = defaults
    }
}
