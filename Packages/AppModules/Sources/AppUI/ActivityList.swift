import AppCore
import SwiftUI

/// How the Activity lists and the queue notification put results into words.
public enum ActivityText {
    /// "1.2 GB → 400 MB"
    public static func sizeChange(_ outcome: JobOutcome) -> String {
        "\(ByteFormat.string(outcome.bytesBefore)) → \(ByteFormat.string(outcome.bytesAfter))"
    }

    /// "Saved 800 MB (−67%)"
    public static func saved(_ outcome: JobOutcome) -> String {
        let saved = "Saved \(ByteFormat.string(outcome.savedBytes))"
        guard let percent = ByteFormat.savedPercent(before: outcome.bytesBefore, after: outcome.bytesAfter) else {
            return saved
        }
        return "\(saved) (\(percent))"
    }

    /// "Converted 3 videos · saved 2.1 GB · 1 kept as is · 1 failed"; parts with nothing to say are left out.
    public static func notificationBody(_ summary: QueueRunSummary) -> String {
        var parts: [String] = []
        if summary.converted > 0 {
            parts.append("Converted \(videos(summary.converted)) · saved \(ByteFormat.string(summary.savedBytes))")
        }
        if summary.keptAsIs > 0 {
            parts.append(
                summary.converted > 0 ? "\(summary.keptAsIs) kept as is" : "\(videos(summary.keptAsIs)) kept as is")
        }
        if summary.failed > 0 { parts.append("\(summary.failed) failed") }
        return parts.joined(separator: " · ")
    }

    /// What adding to the queue skipped, or nil when it skipped nothing: "2 videos are already in the queue."
    /// and "1 video couldn't be added because it's missing or can't be read."
    public static func addNotice(alreadyQueued: Int, unreadable: Int, missing: Int = 0) -> String? {
        // A file that went missing just before it was added and one that can't be read are the same to the user.
        let unreadable = unreadable + missing
        var sentences: [String] = []
        if alreadyQueued > 0 {
            sentences.append("\(videos(alreadyQueued)) \(alreadyQueued == 1 ? "is" : "are") already in the queue.")
        }
        if unreadable > 0 {
            sentences.append(
                "\(videos(unreadable)) couldn't be added because \(unreadable == 1 ? "it's" : "they're") missing or "
                    + "can't be read.")
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    /// "1 video", "3 videos"
    public static func videos(_ count: Int) -> String {
        count == 1 ? "1 video" : "\(count) videos"
    }
}

/// **Verified** or **Completed with warnings**; click for what was kept, changed and lost.
public struct ReportBadge<Footer: View>: View {
    let outcome: JobOutcome
    let footer: Footer
    @State private var isShowingReport = false

    /// `footer` is shown at the bottom of the report popover.
    public init(outcome: JobOutcome, @ViewBuilder footer: () -> Footer) {
        self.outcome = outcome
        self.footer = footer()
    }

    private var title: String { outcome.isVerified ? "Verified" : "Completed with warnings" }

    public var body: some View {
        Button {
            isShowingReport.toggle()
        } label: {
            Label(title, systemImage: outcome.isVerified ? "checkmark.seal" : "exclamationmark.triangle")
                .foregroundStyle(outcome.isVerified ? .green : .orange)
        }
        .buttonStyle(.borderless)
        .help("Show what was kept, changed and lost")
        .accessibilityLabel("\(title). Show the report")
        .popover(isPresented: $isShowingReport, arrowEdge: .bottom) {
            ReportPopover(outcome: outcome, footer: footer)
        }
    }
}

extension ReportBadge where Footer == EmptyView {
    public init(outcome: JobOutcome) {
        self.init(outcome: outcome) { EmptyView() }
    }
}

private struct ReportPopover<Footer: View>: View {
    let outcome: JobOutcome
    let footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !outcome.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(outcome.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.callout)
                Divider()
            }
            if !outcome.notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(outcome.notes, id: \.self) { note in
                        Label(note, systemImage: "info.circle")
                    }
                }
                .font(.callout)
                Divider()
            }
            MetadataSummary(report: outcome.report)
            footer
        }
        .padding()
        .frame(width: 340, alignment: .leading)
    }
}
