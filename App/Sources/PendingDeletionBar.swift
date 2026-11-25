import AppUI
import SwiftUI

/// The system bottom bar that says originals are waiting to move to Recently Deleted, with the one button that asks
/// Photos to move them. The words come from `PendingDeletionBarContent`.
struct PendingDeletionBar: View {
    let content: PendingDeletionBarContent
    let perform: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(content.title)
                    .font(.headline)
                Text(content.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            if content.isWorking {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Waiting for Photos")
            }
            if let title = content.buttonTitle {
                Button(title, role: content.isDestructiveAction ? .destructive : nil, action: perform)
                    .buttonStyle(.bordered)
                    .accessibilityHint(
                        content.isDestructiveAction ? "Photos asks you to confirm before anything is moved" : "")
            }
        }
        .scenePadding()
    }
}

#Preview("Ready") {
    PendingDeletionBar(content: PendingDeletionBarContent(count: 12, status: .ready), perform: {})
        .frame(width: 900)
}
