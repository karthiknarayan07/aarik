#if os(iOS)
    import AppUI
    import Convert
    import SwiftUI

    /// Native iOS sheet naming what each video would lose and letting the user skip any before queueing.
    struct IOSLossConfirmationSheet: View {
        @Binding var review: LossReview
        let cancel: () -> Void
        let convert: () -> Void

        private var title: String {
            review.entries.count == 1
                ? "1 Video Will Lose Metadata" : "\(review.entries.count) Videos Will Lose Metadata"
        }

        var body: some View {
            NavigationStack {
                List {
                    Section {
                        ForEach($review.entries) { $entry in
                            let lostText = "Loses \(entry.lost.joined(separator: ", "))"
                            Toggle(isOn: $entry.skip) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    StatusLabel(lostText, systemImage: "exclamationmark.triangle", tint: .orange)
                                        .font(.caption)
                                }
                            }
                            .accessibilityLabel("Skip \(entry.name). \(lostText)")
                        }
                    } header: {
                        Text(
                            "Converting can't keep everything in these videos. Turn on Skip for any you'd rather leave as they are."
                        )
                        .textCase(nil)
                    }
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", role: .cancel, action: cancel)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Convert Anyway", action: convert)
                            .buttonStyle(.glassProminent)
                    }
                }
            }
        }
    }
#endif
