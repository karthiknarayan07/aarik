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

    /// Shown instead of the title when the chat is about one video.
    public static let contextTitle = "Ask About This Video"

    /// The starting questions for a chat about one video.
    public static let contextSuggestions: [String] = [
        "Why Is This So Big?", "How Much Would I Save?", "Should I Convert This?",
    ]

    /// Title Case chips; tapping one asks it as written.
    public static let suggestions: [String] = [
        "Find My Biggest Videos", "How Much Can I Save?", "Why Was This Kept?",
    ]
}

/// What a key press in the Mac composer does: Return sends, Shift-Return (or Option-Return) adds a line, Escape stops
/// an answer being written. Kept apart from the view so the rules are tested.
public enum ComposerKey {
    public enum Action: Equatable, Sendable {
        /// Send the draft.
        case send
        /// Let the text field insert its own newline.
        case newline
        /// Return with nothing to send: the key is swallowed so it doesn't add a blank line.
        case ignoreReturn
        case stop
        /// Not ours.
        case passThrough
    }

    public static func `return`(
        shift: Bool, option: Bool, hasText: Bool, isGenerating: Bool, isComposing: Bool = false
    ) -> Action {
        // A marked-text composition (an input method's candidate) owns Return.
        if isComposing { return .passThrough }
        if shift || option { return .newline }
        return hasText && !isGenerating ? .send : .ignoreReturn
    }

    public static func escape(isGenerating: Bool) -> Action { isGenerating ? .stop : .passThrough }
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

/// The plain text Copy puts on the pasteboard for one message of the transcript.
public enum ChatCopyText {
    public static func string(for content: ChatItem.Content) -> String {
        switch content {
        case .user(let text), .assistant(let text), .notice(let text): text
        case .toolCall(let call): ([ToolCallText.title(call)] + call.lines).joined(separator: "\n")
        case .confirmation(let confirmation):
            [confirmation.card.title, confirmation.card.message, ConfirmationText.status(confirmation)]
                .compactMap { $0 }.joined(separator: "\n")
        }
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
