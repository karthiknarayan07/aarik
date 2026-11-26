#if os(macOS)
    import AppUI
    import Convert
    import LocalLibrary
    import SwiftUI

    /// The storage bar for a list of items, worked out off the main actor whenever the items or presets change.
    struct StorageBarLoader: View {
        let items: [VideoItem]
        let preset: (VideoItem) -> Preset
        /// Changes whenever the presets do (the header's and the per-video ones).
        let presetKey: AnyHashable
        @State private var breakdown = StorageBreakdown(segments: [])

        private struct Key: Hashable {
            let count: Int
            let bytes: Int64
            let presets: AnyHashable
        }

        var body: some View {
            // The task sits on a view that is always there: StorageBar draws nothing until it has segments.
            VStack(spacing: 0) {
                StorageBar(breakdown: breakdown)
                Color.clear.frame(height: 0)
                    .task(id: Key(count: items.count, bytes: items.reduce(0) { $0 + $1.byteSize }, presets: presetKey))
                {
                    let pairs = items.map { (item: $0, preset: preset($0)) }
                    let result = await StorageBreakdown.make(pairs: pairs)
                    guard !Task.isCancelled else { return }
                    breakdown = result
                }
            }
        }
    }

    /// "Space you could save", as System Settings draws Storage: one bar split by quality, with a legend. The
    /// grey part is the videos that are already small and stay as they are.
    struct StorageBar: View {
        let breakdown: StorageBreakdown
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            if !breakdown.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    GeometryReader { proxy in
                        HStack(spacing: 2) {
                            ForEach(breakdown.visible) { segment in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(segment.category.tint.gradient)
                                    .frame(width: width(of: segment, in: proxy.size.width))
                                    .help("\(segment.category.title): \(ByteFormat.string(segment.bytes))")
                            }
                        }
                        .clipShape(.rect(cornerRadius: 5))
                        .animation(Motion.animation(reduceMotion: reduceMotion), value: breakdown)
                    }
                    .frame(height: 14)
                    HStack(spacing: 16) {
                        ForEach(breakdown.visible) { segment in
                            HStack(spacing: 5) {
                                Circle().fill(segment.category.tint).frame(width: 8, height: 8)
                                Text(segment.category.title)
                                Text(ByteFormat.string(segment.bytes))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .accessibilityElement(children: .combine)
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.caption)
                    .lineLimit(1)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Space you could save")
                .accessibilityValue(breakdown.spoken)
                .accessibilityIdentifier("localFiles.storageBar")
            }
        }

        /// Proportional to the segment's bytes, never so thin it disappears.
        private func width(of segment: StorageBreakdown.Segment, in total: CGFloat) -> CGFloat {
            let gaps = CGFloat(max(0, breakdown.visible.count - 1)) * 2
            let usable = max(0, total - gaps)
            guard breakdown.total > 0 else { return 0 }
            return max(6, usable * CGFloat(segment.bytes) / CGFloat(breakdown.total))
        }
    }

    /// The inspector's predicted-savings gauge: a ring with the share saved, and the sizes before and after.
    struct PredictedSavingsGauge: View {
        let prediction: LibraryInsight.Prediction
        let presetName: String?

        private var headline: String {
            prediction.saved > 0 ? "Could save \(ByteFormat.string(prediction.saved))" : "Nothing to save"
        }

        private var detail: String {
            guard prediction.saved > 0 else { return "This video is already about as small as it gets." }
            let sizes = "\(ByteFormat.string(prediction.before)) → about \(ByteFormat.string(prediction.after))"
            return prediction.count > 1 && prediction.keptCount > 0
                ? "\(sizes) · \(prediction.keptCount) stay as they are" : sizes
        }

        var body: some View {
            HStack(spacing: 14) {
                ProgressRing(value: prediction.fraction, tint: .green, lineWidth: 7) {
                    Text(prediction.fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.system(.callout, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline).font(.headline)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let presetName {
                        Text("At the \(presetName) preset")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Predicted savings")
            .accessibilityValue(
                [headline, detail, presetName.map { "At the \($0) preset" }].compactMap { $0 }.joined(separator: ". "))
        }
    }

    /// Metadata chips in a wrapping row.
    struct ChipRow: View {
        let chips: [LibraryChip]

        var body: some View {
            WrappingRow(spacing: 6) {
                ForEach(chips) { chip in
                    Label(chip.title, systemImage: chip.systemImage)
                        .font(.caption.weight(.medium))
                        .labelStyle(ChipLabelStyle(tint: chip.tint))
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// Lays its children out left to right and starts a new line when one doesn't fit.
    struct WrappingRow: Layout {
        var spacing: CGFloat = 6

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            arrange(subviews, width: proposal.width ?? .infinity).size
        }

        func placeSubviews(
            in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
        ) {
            let arranged = arrange(subviews, width: bounds.width)
            for (subview, origin) in zip(subviews, arranged.origins) {
                subview.place(
                    at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
            }
        }

        private func arrange(_ subviews: Subviews, width: CGFloat) -> (origins: [CGPoint], size: CGSize) {
            var origins: [CGPoint] = []
            var x: CGFloat = 0
            var y: CGFloat = 0
            var rowHeight: CGFloat = 0
            var widest: CGFloat = 0
            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                if x > 0, x + size.width > width {
                    x = 0
                    y += rowHeight + spacing
                    rowHeight = 0
                }
                origins.append(CGPoint(x: x, y: y))
                x += size.width + spacing
                rowHeight = max(rowHeight, size.height)
                widest = max(widest, x - spacing)
            }
            return (origins, CGSize(width: widest, height: y + rowHeight))
        }
    }

    private struct ChipLabelStyle: LabelStyle {
        let tint: Color

        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 4) {
                configuration.icon.foregroundStyle(tint)
                configuration.title
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary, in: .capsule)
        }
    }
#endif
