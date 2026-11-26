import Assistant
import SwiftUI

#if os(macOS)
    import AppKit
#endif

struct AssistantTranscript: View {
    let chat: AssistantChat
    let reduceMotion: Bool
    /// A readable column on a wide window (the Mac); nil fills the width (the phone).
    var maxContentWidth: CGFloat?
    @State private var wasGenerating = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(chat.items) { item in
                        ChatItemView(item: item, chat: chat, isStreaming: isStreaming(item))
                            .id(item.id)
                    }
                    if chat.isGenerating, showsThinking {
                        ProgressView()
                            .padding(.leading, 4)
                            .accessibilityLabel("Thinking")
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .frame(maxWidth: maxContentWidth ?? .infinity)
                .frame(maxWidth: .infinity)
            }
            #if os(iOS)
                .scrollDismissesKeyboard(.interactively)
            #endif
            .defaultScrollAnchor(.bottom)
            .onChange(of: chat.items.last) { scrollToEnd(proxy) }
            .onChange(of: chat.items.count) { scrollToEnd(proxy) }
            .onChange(of: chat.isGenerating) { _, generating in
                if wasGenerating, !generating {
                    AccessibilityNotification.Announcement("Answer ready").post()
                }
                wasGenerating = generating
            }
        }
    }

    private var showsThinking: Bool {
        switch chat.items.last?.content {
        case .assistant, .confirmation: false
        default: true
        }
    }

    private func isStreaming(_ item: ChatItem) -> Bool {
        chat.isGenerating && item.id == chat.items.last?.id
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        if reduceMotion {
            proxy.scrollTo("end", anchor: .bottom)
        } else {
            withAnimation(.smooth(duration: 0.25)) { proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

struct ChatItemView: View {
    let item: ChatItem
    let chat: AssistantChat
    let isStreaming: Bool

    var body: some View {
        #if os(macOS)
            // Text can be selected and copied (Edit → Copy); the context menu copies the whole message.
            content
                .textSelection(.enabled)
                .contextMenu {
                    Button("Copy", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ChatCopyText.string(for: item.content), forType: .string)
                    }
                }
        #else
            content
        #endif
    }

    @ViewBuilder private var content: some View {
        switch item.content {
        case .user(let text):
            Text(text)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .foregroundStyle(.white)
                .background(.tint, in: .rect(cornerRadius: 20))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 48)
                .accessibilityLabel("You said: \(text)")
        case .assistant(let text):
            Text(Self.rendered(text))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 24)
                .accessibilityLabel("Assistant said: \(text)")
                .accessibilityAddTraits(isStreaming ? .updatesFrequently : [])
        case .toolCall(let call):
            ToolCallRow(call: call)
        case .confirmation(let confirmation):
            ConfirmationCard(
                confirmation: confirmation, confirm: { chat.confirm(item.id) }, cancel: { chat.cancel(item.id) })
        case .notice(let text):
            Label(text, systemImage: "exclamationmark.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private static func rendered(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// "Searched Library · 42 Results": a quiet row that opens to the lines the tool found.
struct ToolCallRow: View {
    let call: ChatToolCall
    @State private var isExpanded = false

    var body: some View {
        Group {
            if call.lines.isEmpty {
                label
            } else {
                DisclosureGroup(isExpanded: $isExpanded) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(call.lines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                } label: {
                    label
                }
                .tint(.secondary)
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ToolCallText.accessibility(call))
    }

    private var label: some View {
        HStack(spacing: 8) {
            switch call.state {
            case .running: ProgressView().controlSize(.small)
            case .done: Image(systemName: "magnifyingglass").foregroundStyle(.tint)
            case .failed: Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            Text(ToolCallText.title(call))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
        }
    }
}

/// An action waiting for a tap, with what it will do. Nothing happens until Confirm.
struct ConfirmationCard: View {
    let confirmation: ChatConfirmation
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(confirmation.card.title, systemImage: "checkmark.shield")
                .font(.headline)
            Text(confirmation.card.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if confirmation.state == .pending {
                HStack(spacing: 10) {
                    Button("Cancel", action: cancel)
                        .buttonStyle(.glass)
                    Button(confirmation.card.confirmLabel, action: confirm)
                        .buttonStyle(.glassProminent)
                }
                .controlSize(.large)
            } else if let status = ConfirmationText.status(confirmation) {
                Text(status)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(confirmation.state == .confirmed ? Color.green : Color.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .sensoryFeedback(.warning, trigger: confirmation.state == .pending)
        .sensoryFeedback(.success, trigger: confirmation.state) { _, new in new == .confirmed }
        .sensoryFeedback(.impact(weight: .light), trigger: confirmation.state) { _, new in new == .cancelled }
        .accessibilityElement(children: .contain)
    }
}
