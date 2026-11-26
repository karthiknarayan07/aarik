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
                StatusLabel(keptTitle, systemImage: "checkmark.circle", tint: .green)
            }
            .accessibilityLabel(keptTitle)
            ForEach(report.changed, id: \.key) { change in
                let line = MetadataSummaryLines.change(change, in: report)
                Label("\(line.name): \(line.from) → \(line.to)", systemImage: "arrow.right.circle")
                    .accessibilityLabel(MetadataNames.changeSentence(change, auxiliaryTracks: line.auxiliary))
            }
            ForEach(MetadataSummaryLines.lost(in: report), id: \.self) { name in
                StatusLabel("\(name) is lost", systemImage: "exclamationmark.triangle", tint: .orange)
            }
        }
        .font(.callout)
    }

    private var keptTitle: String {
        report.kept.count == 1 ? "1 item kept" : "\(report.kept.count) items kept"
    }

    private var keptNames: String {
        MetadataNames.plainNames(of: report.kept, context: report.lost).joined(separator: ", ")
    }
}

/// The plain lines of a report (`MetadataNames`): what is lost, each once, and how a change reads.
enum MetadataSummaryLines {
    static func lost(in report: MetadataReport) -> [String] {
        MetadataNames.plainNames(of: report.lost, context: report.kept)
    }

    static func change(_ change: MetadataChange, in report: MetadataReport)
        -> (name: String, from: String, to: String, auxiliary: Set<Int>)
    {
        let auxiliary = MetadataNames.auxiliaryTracks(in: report.kept + report.lost)
        return (
            MetadataNames.plainName(key: change.key, displayName: change.displayName, auxiliaryTracks: auxiliary),
            MetadataNames.plainValue(key: change.key, value: change.from),
            MetadataNames.plainValue(key: change.key, value: change.to), auxiliary
        )
    }
}
