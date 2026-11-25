import AppCore
import SwiftUI

/// What a conversion is expected to keep, change and lose.
public struct MetadataSummary: View {
    let report: MetadataReport

    public init(report: MetadataReport) {
        self.report = report
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DisclosureGroup {
                Text(keptNames)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            } label: {
                Label(keptTitle, systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            }
            .accessibilityLabel(keptTitle)
            ForEach(report.changed, id: \.key) { change in
                Label("\(change.displayName): \(change.from) → \(change.to)", systemImage: "arrow.right.circle")
                    .accessibilityLabel("\(change.displayName) changes from \(change.from) to \(change.to)")
            }
            ForEach(report.lost, id: \.key) { item in
                Label("\(item.displayName) is lost", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
        .font(.callout)
    }

    private var keptTitle: String {
        report.kept.count == 1 ? "1 item kept" : "\(report.kept.count) items kept"
    }

    private var keptNames: String {
        var seen = Set<String>()
        return report.kept.map(\.displayName).filter { seen.insert($0).inserted }.joined(separator: ", ")
    }
}
