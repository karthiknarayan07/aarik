#if os(macOS)
    import AppCore
    import AppKit
    import Foundation
    import UniformTypeIdentifiers

    /// Which files an entry point (status item drop, popover drop, Services) accepts: movies only. Folders, packages and
    /// everything else are left out, so a drag of a mixed selection converts just its videos.
    public enum MovieDropFilter {
        /// Whether something with this type counts as a video to convert.
        public static func isMovie(contentType: UTType?, isDirectory: Bool, isPackage: Bool) -> Bool {
            guard !isDirectory, !isPackage else { return false }
            return contentType?.conforms(to: .movie) ?? false
        }

        /// The file URLs among `urls` that are movies, in order. A file that can't be read isn't a movie.
        public static func movies(in urls: [URL]) -> [URL] {
            urls.filter { url in
                guard url.isFileURL,
                    let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey, .isPackageKey])
                else { return false }
                return isMovie(
                    contentType: values.contentType, isDirectory: values.isDirectory ?? false,
                    isPackage: values.isPackage ?? false)
            }
        }

        /// The movies on a drag or Services pasteboard (file URLs only).
        public static func movies(on pasteboard: NSPasteboard) -> [URL] {
            let urls =
                pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
                ?? []
            return movies(in: urls)
        }
    }

    /// The "Show in Menu Bar" setting: on unless the person turned it off.
    public enum MenuBarPreference {
        public static let key = "menuBar.showInMenuBar"

        public static func isShown(_ defaults: UserDefaults) -> Bool {
            defaults.object(forKey: key) as? Bool ?? true
        }
    }

    /// What the status item's icon shows. A template SF Symbol: a film stack when idle, a progress ring that fills
    /// with the running job, and a pause mark when jobs wait on a paused queue.
    public enum StatusIconState: Equatable, Sendable {
        case idle
        /// A job is converting (or about to be): progress from 0 to 1.
        case running(progress: Double)
        /// Jobs are waiting and the queue is paused.
        case paused(waiting: Int)

        /// `queueCount` is the jobs queued or running; `runningProgress` is the running job's progress, if one runs.
        public init(queueCount: Int, runningProgress: Double?, isPaused: Bool) {
            if let runningProgress {
                self = .running(progress: min(max(runningProgress, 0), 1))
            } else if queueCount > 0 {
                self = isPaused ? .paused(waiting: queueCount) : .running(progress: 0)
            } else {
                self = .idle
            }
        }

        public init(_ summary: ActivitySummary, isPaused: Bool) {
            self.init(queueCount: summary.queue, runningProgress: summary.runningProgress, isPaused: isPaused)
        }

        public var symbolName: String {
            switch self {
            case .idle: "film.stack"
            case .running: "progress.indicator"
            case .paused: "pause.circle"
            }
        }

        /// For symbols with variable layers; nil for the others.
        public var variableValue: Double? {
            if case .running(let progress) = self { progress } else { nil }
        }

        /// Spoken by VoiceOver after the app's name.
        public var accessibilityStatus: String {
            switch self {
            case .idle: "Queue is empty"
            case .running(let progress): "Converting, \(Int((progress * 100).rounded())) percent"
            case .paused(let waiting): "Queue paused, \(waiting) waiting"
            }
        }
    }

    /// How the transparent drop view over the status item button treats the pointer.
    public enum StatusItemHitTest {
        /// Mouse button events go to the button underneath (so a click still opens the popover); everything else,
        /// which includes the drag, goes to the drop view.
        public static func passesThrough(_ eventType: NSEvent.EventType?) -> Bool {
            switch eventType {
            case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
                true
            default:
                false
            }
        }
    }
#endif
