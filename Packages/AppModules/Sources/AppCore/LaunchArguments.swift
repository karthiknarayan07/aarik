import Foundation

/// Reads `-flag value` pairs from a process's launch arguments (never from stored preferences, so a leftover
/// setting can't change behaviour).
public enum LaunchArguments {
    /// The argument after `flag`; nil when `flag` is absent or last.
    public static func value(of flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}
