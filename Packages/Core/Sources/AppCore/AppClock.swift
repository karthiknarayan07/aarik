import Foundation

/// The current time as the pages show it ("Updated now", "Today", the month's total). Always the system's, except in a
/// Debug build launched with `-uiTestingNow <ISO 8601 date>`, which pins it so UI tests and their reference
/// screenshots are the same on every run. A Release build can't be pinned.
public enum AppClock {
    public static var now: Date { pinned ?? Date() }

    /// The pinned moment, read once from the launch arguments (Debug builds only).
    private static let pinned: Date? = {
        #if DEBUG
            guard let text = LaunchArguments.value(of: "-uiTestingNow", in: ProcessInfo.processInfo.arguments)
            else { return nil }
            return try? Date(text, strategy: .iso8601)
        #else
            return nil
        #endif
    }()

    /// "now", "5 minutes ago", "yesterday": `date` as a phrase relative to `now`.
    public static func relative(_ date: Date, to now: Date = AppClock.now) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
