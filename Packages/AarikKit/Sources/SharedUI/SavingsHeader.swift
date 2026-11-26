import SwiftUI

/// What the savings header says: the amount and a now → after line with a bar, or, when nothing can be freed,
/// one plain sentence without a bar.
struct SavingsSummary: Equatable {
    let couldFree: Int64
    let totalBytes: Int64
    /// How many of the shown videos are available (not missing).
    let availableCount: Int

    var showsBar: Bool { couldFree > 0 }

    var afterBytes: Int64 { max(0, totalBytes - couldFree) }
    var afterFraction: Double { totalBytes > 0 ? Double(afterBytes) / Double(totalBytes) : 1 }

    var title: String {
        showsBar ? "Could free about \(ByteFormat.string(couldFree))" : "Nothing to free here"
    }

    var detail: String {
        guard showsBar else {
            guard totalBytes > 0 else { return "No videos to convert here" }
            return availableCount == 0
                ? "None of these videos are available right now."
                : "These videos are already small or wouldn't get meaningfully smaller"
        }
        return "\(ByteFormat.string(totalBytes)) now → about \(ByteFormat.string(afterBytes)) after · "
            + "Nothing changes until you add to the queue"
    }

    var detailForVoiceOver: String {
        guard showsBar else { return detail }
        return "\(ByteFormat.string(totalBytes)) now, about \(ByteFormat.string(afterBytes)) after. "
            + "Nothing changes until you add to the queue."
    }
}

/// "Could free about X" for what's shown, a now → after bar, and the trust note; "Nothing to free here" when
/// nothing shown would get smaller.
public struct SavingsHeader<Accessory: View>: View {
    let summary: SavingsSummary
    let accessory: Accessory
    @ScaledMetric(relativeTo: .body) private var horizontalPadding: CGFloat = 16
    @ScaledMetric(relativeTo: .body) private var verticalPadding: CGFloat = 10

    public init(couldFree: Int64, totalBytes: Int64, availableCount: Int, @ViewBuilder accessory: () -> Accessory) {
        self.summary = SavingsSummary(couldFree: couldFree, totalBytes: totalBytes, availableCount: availableCount)
        self.accessory = accessory()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                title
                    .font(.title3)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                accessory
            }
            if summary.showsBar {
                SavingsBar(fraction: summary.afterFraction)
                    .accessibilityHidden(true)
            }
            Text(summary.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityLabel(summary.detailForVoiceOver)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
    }

    @ViewBuilder private var title: some View {
        if summary.showsBar {
            Text("Could free about \(Text(ByteFormat.string(summary.couldFree)).foregroundStyle(.tint))")
                .accessibilityLabel(summary.title)
        } else {
            Text(summary.title)
        }
    }
}

/// "3 videos · 1.2 GB"; "0 videos" when there are none.
public enum VideoCount {
    public static func summary(count: Int, bytes: Int64) -> String {
        let videos = count == 1 ? "1 video" : "\(count) videos"
        return count == 0 ? videos : "\(videos) · \(ByteFormat.string(bytes))"
    }
}

/// The whole track is the size now; the filled part is what's left after converting.
private struct SavingsBar: View {
    let fraction: Double

    var body: some View {
        Capsule()
            .fill(.quaternary)
            .frame(height: 6)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(.tint)
                        .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                }
            }
    }
}
