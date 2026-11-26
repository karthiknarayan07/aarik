import Foundation
import Synchronization

/// Shared user pause state exchanged between the app and the Control Center extension through the App Group.
public struct SharedPauseFlag: Codable, Sendable, Equatable {
    public var isPaused: Bool
    public var updatedAt: Date

    public init(isPaused: Bool = false, updatedAt: Date = .now) {
        self.isPaused = isPaused
        self.updatedAt = updatedAt
    }
}

/// Persists `SharedPauseFlag` atomically inside a shared container directory and optionally notifies peers.
public struct SharedPauseFlagStore: Sendable {
    public static let defaultFileName = "pause-flag.json"

    public let directory: URL
    public let fileURL: URL
    public let notificationName: String?

    public init(directory: URL, fileName: String = defaultFileName, notificationName: String? = nil) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent(fileName)
        self.notificationName = notificationName
    }

    /// Creates a store backed by the bundle's App Group container, or returns nil when no container is configured.
    public init?(
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        fileName: String = defaultFileName
    ) {
        guard let groupID = AppGroup.identifier(in: bundle),
            let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: groupID)
        else { return nil }
        self.init(
            directory: container,
            fileName: fileName,
            notificationName: AppGroup.pauseNotificationName(forGroupID: groupID)
        )
    }

    /// Reads the saved pause state, or returns nil if none is saved or the file is unreadable.
    public func load() -> SharedPauseFlag? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SharedPauseFlag.self, from: data)
    }

    /// Whether the shared flag is currently paused (`false` when unset).
    public var isPaused: Bool {
        load()?.isPaused ?? false
    }

    /// Writes `isPaused` when it differs from the current flag (or when setting `true` before any file exists).
    /// Returns true when the flag changed and was written.
    @discardableResult
    public func setPaused(_ isPaused: Bool, updatedAt: Date = .now, notify: Bool = true) throws -> Bool {
        if let existing = load() {
            if existing.isPaused == isPaused { return false }
        } else if !isPaused {
            return false
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(SharedPauseFlag(isPaused: isPaused, updatedAt: updatedAt))
        try data.write(to: fileURL, options: .atomic)
        if notify, let notificationName {
            CrossProcessNotification.post(name: notificationName)
        }
        return true
    }

    /// Flips the current pause state, persists it, and returns the resulting `isPaused` value.
    @discardableResult
    public func toggle(updatedAt: Date = .now, notify: Bool = true) throws -> Bool {
        let next = !isPaused
        try setPaused(next, updatedAt: updatedAt, notify: notify)
        return next
    }
}

/// Posts and observes Darwin notifications across the app and extension processes.
public enum CrossProcessNotification {
    public static func post(name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
    }

    /// Registers an observer until the returned observation is cancelled or deallocated.
    public static func observe(name: String, handler: @escaping @Sendable () -> Void) -> Observation {
        Observation(name: name, handler: handler)
    }

    public final class Observation: Sendable {
        private let state: Mutex<Box?>

        private final class Box: Sendable {
            let name: String
            let handler: @Sendable () -> Void

            init(name: String, handler: @escaping @Sendable () -> Void) {
                self.name = name
                self.handler = handler
            }
        }

        init(name: String, handler: @escaping @Sendable () -> Void) {
            let box = Box(name: name, handler: handler)
            self.state = Mutex(box)
            let pointer = Unmanaged.passUnretained(box).toOpaque()
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                pointer,
                { _, observer, _, _, _ in
                    guard let observer else { return }
                    let box = Unmanaged<Box>.fromOpaque(observer).takeUnretainedValue()
                    box.handler()
                },
                name as CFString,
                nil,
                .deliverImmediately
            )
        }

        public func cancel() {
            let removed = state.withLock { current -> Box? in
                let existing = current
                current = nil
                return existing
            }
            guard let removed else { return }
            withExtendedLifetime(removed) {
                let pointer = Unmanaged.passUnretained(removed).toOpaque()
                CFNotificationCenterRemoveObserver(
                    CFNotificationCenterGetDarwinNotifyCenter(),
                    pointer,
                    CFNotificationName(removed.name as CFString),
                    nil
                )
            }
        }

        deinit {
            cancel()
        }
    }
}
