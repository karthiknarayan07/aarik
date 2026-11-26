import AppCore
import AppKit
import AppServices
import PhotosLibrary

/// Launch arguments for the Mac UI tests (`Apps/macOS/UITests`). None of them does anything in a Release build, and
/// none is read at all unless `-uiTesting <support folder>` is also given, so a normal launch is never affected:
///
/// - `-uiTesting <folder>` keeps the queue, library and stats in `<folder>` (see `MacShell.supportDirectory`).
/// - `-uiTestingFiles <folder>` adds the videos in `<folder>` to Local Files once the app has started.
/// - `-uiTestingWindowSize <width>x<height>` is the window's content size; the saved window frame isn't used.
/// - `-uiTestingNow <ISO 8601 date>` pins the clock the pages show (`AppClock`).
/// - `-uiTestingAssistant unavailable` is a model that is never available (`AppServices.assistantClient`); with
///   `-AssistantDemo` as well, Ask is listed with scripted answers while the Overview's picks fall back to plain rows.
/// - Settings live in a throwaway preferences suite, so a test never reads or changes the real ones; Photos is a fake
///   store that hasn't been asked for access.
@MainActor
enum UITestHooks {
    private static var arguments: [String] { ProcessInfo.processInfo.arguments }

    static var isActive: Bool {
        #if DEBUG
            LaunchArguments.value(of: "-uiTesting", in: arguments) != nil
        #else
            false
        #endif
    }

    /// The preferences the shell reads and writes: the real ones, or in a UI test an empty suite.
    static func defaults() -> UserDefaults {
        #if DEBUG
            if isActive, let id = Bundle.main.bundleIdentifier,
                let suite = UserDefaults(suiteName: "\(id).uitesting")
            {
                suite.removePersistentDomain(forName: "\(id).uitesting")
                return suite
            }
        #endif
        return .standard
    }

    static func photoStore() -> any PhotoStore {
        #if DEBUG
            if isActive { return FakePhotoStore(authorization: .notDetermined) }
        #endif
        return PhotoKitStore()
    }

    /// The window's content size for this launch, if a test asked for one.
    static var windowContentSize: NSSize? {
        #if DEBUG
            guard isActive, let text = LaunchArguments.value(of: "-uiTestingWindowSize", in: arguments) else {
                return nil
            }
            let parts = text.split(separator: "x").compactMap { Double($0) }
            return parts.count == 2 ? NSSize(width: parts[0], height: parts[1]) : nil
        #else
            nil
        #endif
    }

    /// Adds the videos of the `-uiTestingFiles` folder to Local Files.
    static func addFixtureFiles(to shell: MacShell) {
        #if DEBUG
            guard isActive, let folder = LaunchArguments.value(of: "-uiTestingFiles", in: arguments) else { return }
            shell.convert.library.add([URL(filePath: folder, directoryHint: .isDirectory)])
        #endif
    }
}
