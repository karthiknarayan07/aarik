import Assistant
import Foundation

/// The words and symbol for the Ask tab's explanation when the model can't be asked. The tab itself is hidden on
/// devices without Apple Intelligence; this shows only when it drops while the app runs (the model is still
/// downloading, the person turned it off in Settings).
public struct AssistantUnavailableContent: Equatable, Sendable {
    public let title: String
    public let message: String
    public let systemImage: String
    /// Whether Settings is where the person can fix it.
    public let offersSettings: Bool

    public init(_ reason: AssistantUnavailableReason) {
        switch reason {
        case .deviceNotEligible:
            title = "Not Available on This Device"
            message = "Ask needs Apple Intelligence, which this device doesn't support."
            systemImage = "iphone.slash"
            offersSettings = false
        case .notEnabled:
            title = "Apple Intelligence Is Off"
            message =
                "Turn on Apple Intelligence in Settings to ask questions about your videos. Everything stays on this device."
            systemImage = "sparkles"
            offersSettings = true
        case .modelNotReady:
            title = "Getting Ready"
            message = "The on-device model is still downloading. Ask works again when it finishes."
            systemImage = "arrow.down.circle"
            offersSettings = false
        case .unsupportedLanguage:
            title = "Language Not Supported"
            message = "Apple Intelligence doesn't support this device's language yet."
            systemImage = "globe"
            offersSettings = true
        case .unknown:
            title = "Ask Isn't Available"
            message = "The on-device model can't be used right now. Try again in a moment."
            systemImage = "exclamationmark.circle"
            offersSettings = false
        }
    }
}

/// The empty state's text and the three starting questions.
public enum AssistantEmptyContent {
    public static let title = "Ask About Your Videos"
    public static let subtitle =
        "Search your library, estimate savings and explain results. It all runs on this device."

    /// Title Case chips; tapping one asks it as written.
    public static let suggestions: [String] = [
        "Find My Biggest Videos", "How Much Can I Save?", "Why Was This Kept?",
    ]
}

/// "Searched Library · 42 Results" and its VoiceOver reading.
public enum ToolCallText {
    public static func title(_ call: ChatToolCall) -> String {
        guard let count = call.count else { return call.title }
        return "\(call.title) · \(count) \(count == 1 ? "Result" : "Results")"
    }

    public static func accessibility(_ call: ChatToolCall) -> String {
        let state =
            switch call.state {
            case .running: "Working"
            case .done: ""
            case .failed: "Didn't finish"
            }
        return [title(call), state].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// How a confirmation card reads once it has been answered.
public enum ConfirmationText {
    public static func status(_ confirmation: ChatConfirmation) -> String? {
        switch confirmation.state {
        case .pending: nil
        case .confirmed: confirmation.result ?? "Working…"
        case .cancelled: "Cancelled. Nothing was changed."
        case .failed: confirmation.result ?? "That didn't work."
        case .expired: "No longer available. Ask again to start over."
        }
    }
}
