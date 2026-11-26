#if os(iOS)
    import AppServices
    import Assistant
    import SwiftUI

    /// The Ask tab's root: the assistant chat shared by every tool, with its history. The shell shows it only while
    /// `services.assistantAvailability.isAvailable`; inside, an explanation appears only if the model goes away
    /// mid-session.
    public struct AssistantTabRoot: View {
        private let services: AppServices

        public init(services: AppServices) { self.services = services }

        public var body: some View { AssistantChatView(chat: services.assistantChat) }
    }

    struct AssistantChatView: View {
        let chat: AssistantChat
        @Environment(\.openURL) private var openURL
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var draft = ""
        @State private var isShowingHistory = false
        @State private var sendCount = 0
        @State private var stopCount = 0
        @FocusState private var isComposing: Bool

        var body: some View {
            NavigationStack {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background { AssistantBackground() }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if chat.unavailableReason == nil { bottomBar }
                    }
                    .navigationTitle("Ask")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Chat History", systemImage: "line.3.horizontal") { isShowingHistory = true }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("New Chat", systemImage: "square.and.pencil") { newChat() }
                                .disabled(chat.items.isEmpty)
                        }
                    }
                    .sheet(isPresented: $isShowingHistory) { ChatHistorySheet(chat: chat) }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: sendCount)
            .sensoryFeedback(.impact(weight: .medium), trigger: stopCount)
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
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                        .buttonStyle(.glass)
                    }
                }
            } else if chat.items.isEmpty {
                AssistantEmptyState()
            } else {
                AssistantTranscript(chat: chat, reduceMotion: reduceMotion)
            }
        }

        private var bottomBar: some View {
            VStack(spacing: 12) {
                if chat.items.isEmpty {
                    SuggestionChips { ask($0) }
                }
                Composer(
                    draft: $draft, isGenerating: chat.isGenerating, isFocused: $isComposing,
                    send: { ask(draft) }, stop: stop, newChat: newChat, showHistory: { isShowingHistory = true })
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .padding(.top, 8)
        }

        private func ask(_ text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !chat.isGenerating else { return }
            sendCount += 1
            draft = ""
            chat.send(trimmed)
        }

        private func stop() {
            stopCount += 1
            chat.stop()
        }

        private func newChat() {
            chat.newChat()
            draft = ""
        }
    }

    /// A soft gradient that fades from the top of the screen, like the hero of Apple's own onboarding screens.
    struct AssistantBackground: View {
        var body: some View {
            ZStack(alignment: .top) {
                Color(.systemBackground)
                LinearGradient(
                    colors: [.indigo.opacity(0.38), .purple.opacity(0.22), .clear],
                    startPoint: .top, endPoint: .init(x: 0.5, y: 0.75))
            }
            .ignoresSafeArea()
        }
    }

    struct AssistantEmptyState: View {
        @ScaledMetric private var heroSize = 72.0

        var body: some View {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "sparkles")
                    .font(.system(size: heroSize * 0.45, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: heroSize, height: heroSize)
                    .background(
                        LinearGradient(colors: [.indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: .circle
                    )
                    .accessibilityHidden(true)
                Text(AssistantEmptyContent.title)
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(AssistantEmptyContent.subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
                Spacer()
            }
            .padding(.horizontal, 32)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("assistant.empty")
        }
    }

    struct SuggestionChips: View {
        let ask: (String) -> Void

        var body: some View {
            ScrollView(.horizontal, showsIndicators: false) {
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(AssistantEmptyContent.suggestions, id: \.self) { suggestion in
                            Button(suggestion) { ask(suggestion) }
                                .font(.subheadline.weight(.medium))
                                .buttonStyle(.glass)
                        }
                    }
                }
            }
            .scrollClipDisabled()
            .sensoryFeedback(.selection, trigger: 0)
        }
    }

    struct Composer: View {
        @Binding var draft: String
        let isGenerating: Bool
        var isFocused: FocusState<Bool>.Binding
        let send: () -> Void
        let stop: () -> Void
        let newChat: () -> Void
        let showHistory: () -> Void
        @ScaledMetric private var buttonSize = 44.0

        private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        var body: some View {
            GlassEffectContainer(spacing: 8) {
                HStack(alignment: .bottom, spacing: 8) {
                    Menu {
                        Button("New Chat", systemImage: "square.and.pencil", action: newChat)
                        Button("Chat History", systemImage: "clock", action: showHistory)
                    } label: {
                        Image(systemName: "plus")
                            .font(.title3.weight(.medium))
                            .frame(width: buttonSize, height: buttonSize)
                            .contentShape(.circle)
                    }
                    .glassEffect(.regular.interactive(), in: .circle)
                    .accessibilityLabel("More")

                    HStack(alignment: .bottom, spacing: 6) {
                        TextField("Ask Anything", text: $draft, axis: .vertical)
                            .lineLimit(1...5)
                            .focused(isFocused)
                            .submitLabel(.send)
                            .onSubmit(send)
                            .accessibilityIdentifier("assistant.composer")
                            .padding(.leading, 14)
                            .padding(.vertical, 10)
                        Button(action: isGenerating ? stop : send) {
                            Image(systemName: isGenerating ? "stop.fill" : "arrow.up")
                                .font(.body.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: buttonSize - 10, height: buttonSize - 10)
                                .background(.tint.opacity(isGenerating || canSend ? 1 : 0.35), in: .circle)
                                .contentShape(.circle)
                        }
                        .disabled(!isGenerating && !canSend)
                        .accessibilityLabel(isGenerating ? "Stop" : "Send")
                        .accessibilityIdentifier("assistant.send")
                        .padding(5)
                    }
                    .frame(minHeight: buttonSize)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: buttonSize / 2))
                }
            }
        }
    }
#endif
