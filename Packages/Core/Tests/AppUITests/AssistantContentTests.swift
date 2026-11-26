import Assistant
import Testing

@testable import AppUI

@Suite struct AssistantContentTests {
    @Test func copyingAMessageGivesItsPlainText() {
        #expect(ChatCopyText.string(for: .user("Hello")) == "Hello")
        #expect(ChatCopyText.string(for: .assistant("Hi there.")) == "Hi there.")
        #expect(ChatCopyText.string(for: .notice("Try again.")) == "Try again.")
    }

    @Test func copyingAToolRowGivesItsTitleAndLines() {
        let call = ChatToolCall(
            toolName: "search_library", title: "Searched Library", count: 2, lines: ["A · 1 GB", "B · 2 GB"],
            state: .done)
        #expect(
            ChatCopyText.string(for: .toolCall(call)) == "Searched Library · 2 Results\nA · 1 GB\nB · 2 GB")
    }

    @Test func copyingACardGivesWhatItWillDoAndHowItEnded() {
        let card = AssistantConfirmation(title: "Convert 14 Videos", message: "Save about 6.2 GB?")
        var confirmation = ChatConfirmation(toolName: "convert_videos", arguments: AssistantArguments([:]), card: card)
        #expect(
            ChatCopyText.string(for: .confirmation(confirmation)) == "Convert 14 Videos\nSave about 6.2 GB?")
        confirmation.state = .cancelled
        #expect(
            ChatCopyText.string(for: .confirmation(confirmation))
                == "Convert 14 Videos\nSave about 6.2 GB?\nCancelled. Nothing was changed.")
    }

    @Test func suggestionsAreTitleCase() {
        let small: Set<String> = ["a", "an", "the", "of", "to", "in", "on", "and", "or", "for", "from"]
        for text in AssistantEmptyContent.suggestions + AssistantEmptyContent.contextSuggestions
            + [AssistantEmptyContent.title, AssistantEmptyContent.contextTitle]
        {
            let words = text.replacing("?", with: "").split(separator: " ")
            for (index, word) in words.enumerated() where index == 0 || !small.contains(word.lowercased()) {
                #expect(word.first?.isUppercase == true, "\(text)")
            }
        }
    }
}
