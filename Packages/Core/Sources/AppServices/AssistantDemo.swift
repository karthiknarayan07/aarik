#if DEBUG
    import Assistant
    import Foundation

    /// The Debug build's `-AssistantDemo` launch: a scripted model with made-up tools and an in-memory history, so the
    /// Ask tab can be shown (and screenshotted) where Apple Intelligence isn't available. Touches no library or queue.
    @MainActor
    enum AssistantDemo {
        private struct DemoTool: AssistantTool {
            let name: String
            let requiresConfirmation: Bool
            let output: AssistantToolOutput
            var summary: String { "Demo." }

            func confirmation(for arguments: AssistantArguments) async throws -> AssistantConfirmation {
                AssistantConfirmation(
                    title: "Convert 14 Videos", message: "Save about 6.2 GB?", confirmLabel: "Confirm")
            }

            func run(_ arguments: AssistantArguments) async throws -> AssistantToolOutput { output }
        }

        static func makeChat() -> AssistantChat {
            let tools: [any AssistantTool] = [
                DemoTool(
                    name: "search_library", requiresConfirmation: false,
                    output: AssistantToolOutput(
                        text: "42 videos found.", title: "Searched Library", count: 42,
                        lines: [
                            "Beach Day 4K60 · 1.8 GB", "Birthday Dinner 4K30 · 1.2 GB", "Hike Summit 4K60 · 1.1 GB",
                            "Fireworks 4K30 · 940 MB",
                        ])),
                DemoTool(
                    name: "estimate_savings", requiresConfirmation: false,
                    output: AssistantToolOutput(
                        text: "About 6.2 GB across 14 videos.", title: "Estimated Savings", count: 14,
                        lines: ["4K60 from 2025 · Photos · about 3.9 GB", "4K30 from 2024 · Photos · about 2.3 GB"])),
                DemoTool(
                    name: "convert_videos", requiresConfirmation: true,
                    output: AssistantToolOutput(text: "14 videos are in the queue.", title: "Queued Videos", count: 14)),
            ]
            let client = ScriptedChatClient(chunk: 3, delay: .milliseconds(25)) { prompt in
                let text = prompt.lowercased()
                if text.contains("biggest") {
                    return [
                        .tool("search_library"),
                        .text(
                            "Your biggest videos are 4K clips from last summer. The largest is Beach Day at 1.8 GB, then Birthday Dinner at 1.2 GB."
                        ),
                    ]
                }
                if text.contains("save") {
                    return [
                        .tool("estimate_savings"),
                        .text(
                            "Converting your biggest 4K videos could free about 6.2 GB. Want me to queue them?"),
                    ]
                }
                if text.contains("convert") || text.contains("queue") {
                    return [.tool("convert_videos"), .text("Done. 14 videos are in the queue.")]
                }
                if text.contains("kept") {
                    return [
                        .text(
                            "A video is kept as is when converting wouldn't make it meaningfully smaller, so no new file is made and the original stays untouched."
                        )
                    ]
                }
                return [
                    .text(
                        "I can search your library, estimate savings and explain results. What would you like to know?")
                ]
            }
            return AssistantChat(
                client: client, availability: AssistantAvailability(client: client, observesActivation: false),
                store: ChatStore(directory: nil), tools: { tools })
        }
    }
#endif
