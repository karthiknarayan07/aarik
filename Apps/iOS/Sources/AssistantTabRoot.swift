import SwiftUI

/// The Ask tab's root. A placeholder: the assistant chat is built in its own files and replaces the body of this view.
struct AssistantTabRoot: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Ask About Your Videos", systemImage: "sparkles",
                description: Text(
                    "Ask for the biggest videos, what to convert first, or how much space you could free.")
            )
            .navigationTitle("Ask")
        }
    }
}
