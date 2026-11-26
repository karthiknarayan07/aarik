#if os(macOS)
    import AppUI
    import Charts
    import Convert
    import SwiftUI

    /// The Overview's top half, drawn from cached numbers: a savings ring with one sentence about it, a row of summary
    /// cards that each hold a small chart, and larger trend charts. System colours only (so they follow the appearance and
    /// Increase Contrast); every chart has a spoken summary and per-mark values, and a chart without data says so.
    struct OverviewInsights: View {
        let charts: OverviewCharts
        let presetName: String
        let isRefreshing: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 20) {
                SavingsHero(charts: charts, presetName: presetName, isRefreshing: isRefreshing)
                AdaptiveGrid(minimumWidth: 190, spacing: 12, isBalanced: true) {
                    SummaryCard(
                        title: "Could Free", systemImage: "arrow.down.right.circle.fill", tint: .blue,
                        value: charts.couldFree > 0 ? ByteFormat.string(charts.couldFree) : "Nothing",
                        detail: "at the \(presetName) preset"
                    ) {
                        MiniBars(
                            values: charts.sizes.flatMap { [$0.now, $0.after] }.map(Double.init), tint: .blue,
                            dimsFirst: true)
                    }
                    SummaryCard(
                        title: "Saved So Far", systemImage: "checkmark.circle.fill", tint: .green,
                        value: ByteFormat.string(charts.savedBytes),
                        detail: charts.hasHistory ? "across all conversions" : "after the first conversion"
                    ) {
                        MiniArea(points: charts.savedOverTime, tint: .green)
                    }
                    SummaryCard(
                        title: "Converted", systemImage: "film.stack.fill", tint: .orange,
                        value: charts.conversions.formatted(),
                        detail: charts.conversions == 1 ? "video" : "videos"
                    ) {
                        MiniBars(
                            values: charts.throughput.map { Double($0.videos) }, tint: .orange,
                            singleCaption: "Not enough history yet")
                    }
                    SummaryCard(
                        title: "Biggest Group", systemImage: "rectangle.stack.fill", tint: .purple,
                        value: charts.groups.first.map { ByteFormat.string($0.bytes) } ?? "None",
                        detail: charts.groups.first?.title ?? "Nothing to free"
                    ) {
                        MiniBars(values: charts.groups.map { Double($0.bytes) }, tint: .purple)
                    }
                }
                Text("Trends")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                AdaptiveGrid(minimumWidth: 340, spacing: 16) {
                    BeforeAfterChart(sizes: charts.sizes)
                    GroupSavingsChart(groups: charts.groups)
                    SavedOverTimeChart(points: charts.savedOverTime)
                    ThroughputChart(days: charts.throughput)
                }
            }
        }
    }

    // MARK: - Hero

    /// A ring of how much of the library could go, beside one sentence that says it in words.
    private struct SavingsHero: View {
        let charts: OverviewCharts
        let presetName: String
        let isRefreshing: Bool

        private struct Slice: Identifiable {
            let name: String
            let bytes: Double
            var id: String { name }
        }

        private var slices: [Slice] {
            guard charts.totalBytes > 0 else { return [] }
            return [
                Slice(name: "Could free", bytes: Double(charts.couldFree)),
                Slice(name: "Stays", bytes: Double(max(0, charts.totalBytes - charts.couldFree))),
            ]
        }

        private var percent: String { charts.freeFraction.formatted(.percent.precision(.fractionLength(0))) }

        /// The headline, in words, for what the ring shows.
        private var insight: String {
            guard charts.totalBytes > 0 else { return "Add videos to see what converting them could free." }
            guard charts.couldFree > 0 else { return "Your videos are already about as small as they get." }
            return
                "Converting could free about \(ByteFormat.string(charts.couldFree)), \(percent) of your videos' size."
        }

        var body: some View {
            GroupBox {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 24) {
                        ring; words
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        ring; words
                    }
                }
                .padding(8)
            }
        }

        private var words: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(insight)
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if charts.couldFree > 0 {
                    Text(
                        "\(ByteFormat.string(charts.totalBytes)) now, about "
                            + "\(ByteFormat.string(max(0, charts.totalBytes - charts.couldFree))) after at the "
                            + "\(presetName) preset."
                    )
                    .foregroundStyle(.secondary)
                }
                Text("Nothing changes until you add videos to the queue.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    if isRefreshing {
                        ProgressView().controlSize(.small)
                        Text("Updating…")
                    } else {
                        Text("Updated \(charts.updatedAt.formatted(.relative(presentation: .named)))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private var ring: some View {
            Chart {
                if slices.isEmpty {
                    SectorMark(angle: .value("Empty", 1), innerRadius: .ratio(0.72))
                        .foregroundStyle(Color(nsColor: .quaternaryLabelColor))
                } else {
                    ForEach(slices) { slice in
                        SectorMark(angle: .value("Size", slice.bytes), innerRadius: .ratio(0.72), angularInset: 1.5)
                            .cornerRadius(5)
                            .foregroundStyle(by: .value("Part", slice.name))
                    }
                }
            }
            .chartForegroundStyleScale(["Could free": Color.blue, "Stays": Color(nsColor: .quaternaryLabelColor)])
            .chartLegend(.hidden)
            .chartBackground { _ in
                VStack(spacing: 0) {
                    Text(charts.couldFree > 0 ? percent : "—")
                        .font(.system(.title, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                    Text("smaller")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 132, height: 132)
            .accessibilityLabel("Share of your videos that could be freed")
            .accessibilityValue(
                charts.couldFree > 0 ? "\(percent), about \(ByteFormat.string(charts.couldFree))" : "None")
        }
    }

    // MARK: - Summary cards

    /// One pinned figure with a small chart under it.
    private struct SummaryCard<Sparkline: View>: View {
        let title: String
        let systemImage: String
        let tint: Color
        let value: String
        let detail: String
        @ViewBuilder let sparkline: Sparkline

        var body: some View {
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Label(title, systemImage: systemImage)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(tint)
                    Text(value)
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    sparkline
                        .frame(height: 36)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue("\(value), \(detail)")
        }
    }

    /// The shape of a series, not its numbers. Three or more values are bars; with fewer a bar chart would be a few
    /// stray strokes, so two values are drawn as proportional capsules, and one is a full capsule (or `singleCaption`).
    private struct MiniBars: View {
        let values: [Double]
        let tint: Color
        var dimsFirst = false
        var singleCaption: String?

        var body: some View {
            if values.count >= 3 {
                Chart(Array(values.enumerated()), id: \.offset) { entry in
                    BarMark(x: .value("Item", entry.offset), y: .value("Value", entry.element), width: .ratio(0.7))
                        .foregroundStyle(tint.gradient)
                        .cornerRadius(2)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
            } else if values.count == 1, let singleCaption {
                Text(singleCaption)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else if values.isEmpty {
                Color.clear
            } else {
                let top = max(values.max() ?? 1, 1)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(values.enumerated()), id: \.offset) { entry in
                        GeometryReader { proxy in
                            Capsule()
                                .fill(tint.opacity(dimsFirst && entry.offset == 0 && values.count == 2 ? 0.4 : 1))
                                .frame(width: max(6, proxy.size.width * entry.element / top))
                        }
                        .frame(height: 10)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
    }

    private struct MiniArea: View {
        let points: [OverviewCharts.SavedPoint]
        let tint: Color

        var body: some View {
            if points.count < 2 {
                // A line needs two points; one would be a lone dot.
                Text("Not enough history yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                Chart(points) { point in
                    AreaMark(x: .value("Day", point.day, unit: .day), y: .value("Saved", point.cumulativeBytes))
                        .foregroundStyle(tint.opacity(0.25).gradient)
                    LineMark(x: .value("Day", point.day, unit: .day), y: .value("Saved", point.cumulativeBytes))
                        .foregroundStyle(tint)
                        .interpolationMethod(.monotone)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
            }
        }
    }

    /// Equal columns, as many as fit at `minimumWidth`, one row after another. Not lazy, so every row has its real
    /// height at once and nothing below it can be laid over it while the charts size themselves.
    private struct AdaptiveGrid: Layout {
        let minimumWidth: CGFloat
        let spacing: CGFloat
        /// Only column counts that fill every row (4 cards go 4, 2 or 1 across, never 3 + 1).
        var isBalanced = false

        private func columns(for width: CGFloat, count: Int) -> Int {
            guard width.isFinite, width > 0 else { return 1 }
            var columns = max(1, Int((width + spacing) / (minimumWidth + spacing)))
            if isBalanced {
                columns = min(columns, max(count, 1))
                while columns > 1 && count % columns != 0 { columns -= 1 }
            }
            return columns
        }

        private func cellWidth(_ width: CGFloat, columns: Int) -> CGFloat {
            (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        }

        private func rowHeights(_ subviews: Subviews, width: CGFloat) -> (heights: [CGFloat], columns: Int) {
            let count = columns(for: width, count: subviews.count)
            let cell = cellWidth(width, columns: count)
            var heights: [CGFloat] = []
            for start in stride(from: 0, to: subviews.count, by: count) {
                let row = subviews[start..<min(start + count, subviews.count)]
                heights.append(
                    row.map { $0.sizeThatFits(ProposedViewSize(width: cell, height: nil)).height }.max() ?? 0)
            }
            return (heights, count)
        }

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let width = proposal.width ?? minimumWidth
            let rows = rowHeights(subviews, width: width).heights
            return CGSize(width: width, height: rows.reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1)))
        }

        func placeSubviews(
            in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
        ) {
            let (heights, count) = rowHeights(subviews, width: bounds.width)
            let cell = cellWidth(bounds.width, columns: count)
            var y = bounds.minY
            for (rowIndex, height) in heights.enumerated() {
                for column in 0..<count {
                    let index = rowIndex * count + column
                    guard index < subviews.count else { break }
                    subviews[index].place(
                        at: CGPoint(x: bounds.minX + CGFloat(column) * (cell + spacing), y: y), anchor: .topLeading,
                        proposal: ProposedViewSize(width: cell, height: height))
                }
                y += height + spacing
            }
        }
    }
#endif
