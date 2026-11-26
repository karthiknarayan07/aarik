import Convert
import AppUI
import SwiftUI

/// Names what each video would lose, lets the user skip any of them, then converts the rest (spec 8.4).
struct LossConfirmationSheet: View {
    @Binding var review: LossReview
    let cancel: () -> Void
    let convert: () -> Void

    private var title: String {
        review.entries.count == 1 ? "1 video will lose metadata" : "\(review.entries.count) videos will lose metadata"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            Text("Converting can't keep everything in these videos. Skip any you'd rather leave as they are.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List($review.entries) { $entry in
                LossRow(entry: $entry)
            }
            .listStyle(.bordered)
            .frame(minHeight: 120, idealHeight: 220)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Convert Anyway", action: convert)
                    .keyboardShortcut(.defaultAction)
                    .help("Add the videos to the queue, except the ones you skip")
            }
        }
        // The system's form-sized sheet, with its standard padding, instead of a hand-set width.
        .scenePadding()
        .presentationSizing(.form)
    }
}

private struct LossRow: View {
    @Binding var entry: LossReview.Entry

    private var lostText: String { "Loses \(entry.lost.joined(separator: ", "))" }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                StatusLabel(lostText, systemImage: "exclamationmark.triangle", tint: .orange)
                    .font(.caption)
            }
            Spacer()
            Toggle("Skip This Video", isOn: $entry.skip)
                .toggleStyle(.checkbox)
                .accessibilityLabel("Skip \(entry.name)")
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(entry.name). \(lostText)")
    }
}
