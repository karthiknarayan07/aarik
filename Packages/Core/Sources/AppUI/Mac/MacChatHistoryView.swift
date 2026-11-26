#if os(macOS)
    import Assistant
    import SwiftUI

    /// The Ask page's inspector: the saved chats, newest first. Click one to open it; the context menu renames or
    /// deletes it (the chat only, never a video). Chats are kept on this Mac.
    public struct MacChatHistoryView: View {
        let chat: AssistantChat
        @State private var renaming: ChatConversationSummary?
        @State private var newTitle = ""
        @State private var deleting: ChatConversationSummary?

        public init(chat: AssistantChat) { self.chat = chat }

        public var body: some View {
            Group {
                if chat.conversations.isEmpty {
                    ContentUnavailableView(
                        "No Chats Yet", systemImage: "bubble.left.and.bubble.right",
                        description: Text("Your questions and answers are saved here, on this Mac."))
                } else {
                    List(selection: selection) {
                        Section("Chats") {
                            ForEach(chat.conversations) { conversation in
                                MacChatRow(conversation: conversation)
                                    .tag(conversation.id)
                                    .contextMenu {
                                        Button("Rename…", systemImage: "pencil") { beginRename(conversation) }
                                        Divider()
                                        Button("Delete Chat…", systemImage: "trash", role: .destructive) {
                                            deleting = conversation
                                        }
                                    }
                            }
                        }
                    }
                    .onDeleteCommand {
                        deleting = chat.conversations.first { $0.id == chat.currentID }
                    }
                }
            }
            .onAppear { chat.refreshConversations() }
            .alert("Rename Chat", isPresented: isRenaming) {
                TextField("Title", text: $newTitle)
                Button("Rename") {
                    if let renaming { chat.rename(renaming.id, to: newTitle) }
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(
                "Delete This Chat?", isPresented: isDeleting, titleVisibility: .visible, presenting: deleting
            ) { conversation in
                Button("Delete Chat", role: .destructive) { chat.delete(conversation.id) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("The chat is removed from this Mac. Your videos are not affected.")
            }
        }

        private var selection: Binding<UUID?> {
            Binding {
                chat.currentID
            } set: { id in
                if let id { chat.open(id) }
            }
        }

        private var isRenaming: Binding<Bool> {
            Binding {
                renaming != nil
            } set: {
                if !$0 { renaming = nil }
            }
        }

        private var isDeleting: Binding<Bool> {
            Binding {
                deleting != nil
            } set: {
                if !$0 { deleting = nil }
            }
        }

        private func beginRename(_ conversation: ChatConversationSummary) {
            newTitle = conversation.title
            renaming = conversation
        }
    }

    /// A chat's title, what it ended with, and when.
    struct MacChatRow: View {
        let conversation: ChatConversationSummary

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.title)
                    .lineLimit(1)
                if !conversation.preview.isEmpty {
                    Text(conversation.preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(conversation.updatedAt, format: .relative(presentation: .named))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
        }
    }
#endif
