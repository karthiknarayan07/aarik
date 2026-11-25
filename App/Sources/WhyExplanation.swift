import AppCore
import Assistant
import SwiftUI

/// "Why?" on a result row: explains the result in plain words, on this Mac. Not there at all while Apple
/// Intelligence is unavailable.
struct WhyButton: View {
    let assistant: AssistantServices
    let job: Job
    let outcome: JobOutcome?
    @State private var isShowing = false

    var body: some View {
        if assistant.isAvailable {
            Button("Why?", systemImage: "sparkles") { isShowing.toggle() }
                .buttonStyle(.borderless)
                .help("Explain this result in plain words")
                .accessibilityLabel("Why? Explain this result")
                .popover(isPresented: $isShowing, arrowEdge: .bottom) {
                    WhyText(assistant: assistant, job: job, outcome: outcome)
                        .padding()
                        .frame(width: 320, alignment: .leading)
                }
        }
    }
}

/// "Why?" at the bottom of a report popover; the answer replaces the button.
struct WhyInline: View {
    let assistant: AssistantServices
    let job: Job
    let outcome: JobOutcome
    @State private var isRevealed = false

    var body: some View {
        if assistant.isAvailable {
            Divider()
            if isRevealed {
                WhyText(assistant: assistant, job: job, outcome: outcome)
            } else {
                Button("Why?", systemImage: "sparkles") { isRevealed = true }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Why? Explain this result")
            }
        }
    }
}

/// The explanation, written when first shown and remembered for the job.
private struct WhyText: View {
    let assistant: AssistantServices
    let job: Job
    let outcome: JobOutcome?
    @State private var text: String?

    var body: some View {
        Group {
            if let text {
                Text(text)
                    .textSelection(.enabled)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Working it out on this Mac…").foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
        .task(id: job) {
            text = await assistant.explanations.explain(job: job, outcome: outcome)
        }
    }
}
