#if os(iOS)
    import Assistant
    import SwiftUI

    /// The list of past chats: open one, rename it, start a new one, or swipe to delete (the chat only).
    struct ChatHistorySheet: View {
        let chat: AssistantChat
        @Environment(\.dismiss) private var dismiss
        @State private var renaming: ChatConversationSummary?
        @State private var newTitle = ""

        var body: some View {
            NavigationStack {
                Group {
                    if chat.conversations.isEmpty {
                        ContentUnavailableView(
                            "No Chats Yet", systemImage: "bubble.left.and.bubble.right",
                            description: Text("Your questions and answers are saved here, on this device."))
                    } else {
                        List {
                            ForEach(chat.conversations) { conversation in
                                row(conversation)
                            }
                        }
                    }
                }
                .navigationTitle("Chats")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("New Chat", systemImage: "square.and.pencil") {
                            chat.newChat()
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
                .alert("Rename Chat", isPresented: isRenaming) {
                    TextField("Title", text: $newTitle)
                    Button("Rename") {
                        if let renaming { chat.rename(renaming.id, to: newTitle) }
                    }
                    Button("Cancel", role: .cancel) {}
                }
            }
            .presentationDetents([.medium, .large])
            .onAppear { chat.refreshConversations() }
        }

        private var isRenaming: Binding<Bool> {
            Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
        }

        private func row(_ conversation: ChatConversationSummary) -> some View {
            Button {
                chat.open(conversation.id)
                dismiss()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(conversation.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if !conversation.preview.isEmpty {
                            Text(conversation.preview)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Text(conversation.updatedAt, format: .relative(presentation: .named))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if conversation.id == chat.currentID {
                        Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityLabel("Open")
                    }
                }
            }
            .swipeActions(edge: .trailing) {
                Button("Delete", systemImage: "trash", role: .destructive) { chat.delete(conversation.id) }
            }
            .swipeActions(edge: .leading) {
                Button("Rename", systemImage: "pencil") { beginRename(conversation) }
                    .tint(.orange)
            }
            .contextMenu {
                Button("Rename", systemImage: "pencil") { beginRename(conversation) }
                Button("Delete", systemImage: "trash", role: .destructive) { chat.delete(conversation.id) }
            }
        }

        private func beginRename(_ conversation: ChatConversationSummary) {
            newTitle = conversation.title
            renaming = conversation
        }
    }
#endif
