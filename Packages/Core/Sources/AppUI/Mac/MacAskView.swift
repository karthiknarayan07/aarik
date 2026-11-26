#if os(macOS)
    import AppKit
    import Assistant
    import SwiftUI

    /// The Ask page on the Mac: the conversation with the on-device assistant and a composer at the bottom. Return
    /// sends, Shift-Return adds a line, Esc stops an answer being written. The chat history is the page's inspector
    /// (`MacChatHistoryView`) and New Chat is in the File menu, so this view holds neither.
    ///
    /// The transcript, tool rows and confirmation cards are the ones the iPhone uses (`AssistantTranscript`).
    public struct MacAskView: View {
        let chat: AssistantChat
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var draft = ""
        @FocusState private var isComposing: Bool

        public init(chat: AssistantChat) { self.chat = chat }

        public var body: some View {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Ask")
                .safeAreaBar(edge: .bottom, spacing: 0) {
                    if chat.unavailableReason == nil { bottomBar }
                }
                .defaultFocus($isComposing, true)
                .onKeyPress(.escape) {
                    guard ComposerKey.escape(isGenerating: chat.isGenerating) == .stop else { return .ignored }
                    chat.stop()
                    return .handled
                }
                // A new or another chat starts with an empty field and the cursor in it.
                .onChange(of: chat.currentID) {
                    draft = ""
                    isComposing = true
                }
        }

        @ViewBuilder private var content: some View {
            if let reason = chat.unavailableReason {
                let text = AssistantUnavailableContent(reason)
                ContentUnavailableView {
                    Label(text.title, systemImage: text.systemImage)
                } description: {
                    Text(text.message)
                } actions: {
                    if text.offersSettings {
                        Button("Open System Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            } else if chat.items.isEmpty {
                MacAskEmptyState(hasContext: chat.context != nil, ask: send)
            } else {
                AssistantTranscript(chat: chat, reduceMotion: reduceMotion, maxContentWidth: 760)
            }
        }

        private var bottomBar: some View {
            VStack(spacing: 8) {
                if let context = chat.context {
                    MacAskContextChip(context: context, remove: chat.clearContext)
                }
                MacComposer(
                    draft: $draft, isGenerating: chat.isGenerating, isFocused: $isComposing, send: { send(draft) },
                    stop: chat.stop)
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
        }

        private func send(_ text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !chat.isGenerating else { return }
            draft = ""
            chat.send(trimmed)
        }
    }

    /// The first thing in a new chat: what Ask can do, and a few questions to start with.
    struct MacAskEmptyState: View {
        let hasContext: Bool
        let ask: (String) -> Void

        var body: some View {
            VStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 76, height: 76)
                    .background(
                        LinearGradient(colors: [.indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: .circle
                    )
                    .accessibilityHidden(true)
                Text(hasContext ? AssistantEmptyContent.contextTitle : AssistantEmptyContent.title)
                    .font(.title.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(AssistantEmptyContent.subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(
                            hasContext ? AssistantEmptyContent.contextSuggestions : AssistantEmptyContent.suggestions,
                            id: \.self
                        ) {
                            suggestion in
                            Button(suggestion) { ask(suggestion) }
                                .buttonStyle(.glass)
                        }
                    }
                }
                .padding(.top, 8)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// "About Beach Day.mov", with a button to drop it. Sits above the composer.
    struct MacAskContextChip: View {
        let context: ChatContext
        let remove: () -> Void

        var body: some View {
            HStack(spacing: 6) {
                Image(systemName: "film")
                    .foregroundStyle(.tint)
                Text("About \(context.title)")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Remove Context", systemImage: "xmark.circle.fill", action: remove)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Stop asking about this video")
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
        }
    }

    /// The field and its Send or Stop button.
    struct MacComposer: View {
        @Binding var draft: String
        let isGenerating: Bool
        var isFocused: FocusState<Bool>.Binding
        let send: () -> Void
        let stop: () -> Void

        private var hasText: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        var body: some View {
            HStack(alignment: .bottom, spacing: 8) {
                // The invisible text sizes the field: one line, growing to six, then it scrolls.
                Text(draft.isEmpty ? " " : draft + "\u{200B}")
                    .font(.body)
                    .lineLimit(1...6)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(0)
                    .accessibilityHidden(true)
                    .overlay {
                        TextEditor(text: $draft)
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .focused(isFocused)
                            .accessibilityLabel("Message")
                            .accessibilityIdentifier("assistant.composer")
                            .onKeyPress(.return, phases: .down) { press in
                                let action = ComposerKey.return(
                                    shift: press.modifiers.contains(.shift), option: press.modifiers.contains(.option),
                                    hasText: hasText, isGenerating: isGenerating)
                                switch action {
                                case .send:
                                    send()
                                    return .handled
                                case .ignoreReturn: return .handled
                                case .newline, .stop, .passThrough: return .ignored
                                }
                            }
                            .overlay(alignment: .topLeading) {
                                if draft.isEmpty {
                                    Text("Ask Anything")
                                        .font(.body)
                                        .foregroundStyle(.tertiary)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .allowsHitTesting(false)
                                        .accessibilityHidden(true)
                                }
                            }
                    }
                Button(action: isGenerating ? stop : send) {
                    Image(systemName: isGenerating ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 26))
                        .symbolRenderingMode(.hierarchical)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .foregroundStyle(isGenerating || hasText ? Color.accentColor : Color.secondary.opacity(0.5))
                .disabled(!isGenerating && !hasText)
                .help(isGenerating ? "Stop (Esc)" : "Send (Return)")
                .accessibilityLabel(isGenerating ? "Stop" : "Send")
                .accessibilityIdentifier("assistant.send")
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
        }
    }
#endif
