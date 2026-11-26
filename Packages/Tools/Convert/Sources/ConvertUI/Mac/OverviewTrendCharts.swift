#if os(macOS)
    import AppUI
    import Charts
    import Convert
    import SwiftUI

    /// A titled box for one chart, with a note in place of the chart when there is nothing to draw.
    struct ChartBox<Content: View>: View {
        let title: String
        let subtitle: String
        let isEmpty: Bool
        let emptyText: String
        /// With exactly one data point a trend can't be drawn; this says the value instead (value, then a caption).
        var single: (value: String, caption: String)?
        @ViewBuilder let content: Content

        var body: some View {
            GroupBox {
                Group {
                    if isEmpty {
                        Text(emptyText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, minHeight: Self.height)
                    } else if let single {
                        VStack(spacing: 4) {
                            Text(single.value)
                                .font(.system(.title, design: .rounded, weight: .semibold))
                                .monospacedDigit()
                            Text(single.caption)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Text("Not enough history yet")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: Self.height)
                        .accessibilityElement(children: .combine)
                    } else {
                        content.frame(height: Self.height)
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }

        private static var height: CGFloat { 190 }
    }

    struct BeforeAfterChart: View {
        let sizes: [OverviewCharts.SizePair]

        private struct Bar: Identifiable {
            let library: String
            let kind: String
            let bytes: Int64
            var id: String { "\(library)/\(kind)" }
        }

        private var bars: [Bar] {
            sizes.flatMap {
                [
                    Bar(library: $0.library, kind: "Now", bytes: $0.now),
                    Bar(library: $0.library, kind: "After", bytes: $0.after),
                ]
            }
        }

        var body: some View {
            ChartBox(
                title: "Before and After", subtitle: "Size now and after converting", isEmpty: sizes.isEmpty,
                emptyText: "Add videos or allow access to Photos to compare sizes."
            ) {
                Chart(bars) { bar in
                    BarMark(
                        x: .value("Size", bar.bytes), y: .value("Library", bar.library),
                        height: sizes.count == 1 ? .fixed(18) : .automatic
                    )
                    .foregroundStyle(by: .value("When", bar.kind))
                    .position(by: .value("When", bar.kind))
                    .cornerRadius(3)
                    .annotation(position: .top, alignment: .leading, spacing: 4) {
                        // The library's name once, above its first bar, never over the plot.
                        if bar.kind == "Now" {
                            Text(bar.library)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .accessibilityLabel("\(bar.library), \(bar.kind)")
                    .accessibilityValue(ByteFormat.string(bar.bytes))
                }
                .chartForegroundStyleScale(["Now": Color.indigo.opacity(0.45), "After": Color.indigo])
                .chartXAxis { byteAxisMarks() }
                .chartYAxis(.hidden)
                .chartLegend(position: .bottom, alignment: .leading, spacing: 10)
                .chartPlotStyle { $0.padding(.top, 22).padding(.bottom, 6).padding(.trailing, 12) }
                .accessibilityLabel("Size now and after converting")
                .accessibilityValue(
                    sizes.map {
                        "\($0.library): \(ByteFormat.string($0.now)) now, about \(ByteFormat.string($0.after)) after"
                    }.joined(separator: ". "))
            }
        }
    }

    struct GroupSavingsChart: View {
        let groups: [OverviewCharts.GroupSaving]

        var body: some View {
            ChartBox(
                title: "Savings by Group", subtitle: "What each group could free", isEmpty: groups.isEmpty,
                emptyText: "Nothing here would get meaningfully smaller at this preset."
            ) {
                Chart(groups) { group in
                    BarMark(
                        x: .value("Could Free", group.bytes), y: .value("Group", group.title),
                        height: groups.count == 1 ? .fixed(24) : .automatic
                    )
                    .foregroundStyle(Color.blue.gradient)
                    .cornerRadius(3)
                    .annotation(position: .top, alignment: .leading, spacing: 4) {
                        Text(group.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .accessibilityLabel(group.title)
                    .accessibilityValue("could free about \(ByteFormat.string(group.bytes))")
                }
                .chartXAxis { byteAxisMarks() }
                .chartYAxis(.hidden)
                .chartPlotStyle { $0.padding(.top, 22).padding(.bottom, 6).padding(.trailing, 12) }
                .accessibilityLabel("What each group of videos could free")
                .accessibilityValue(
                    groups.map { "\($0.title): about \(ByteFormat.string($0.bytes))" }.joined(separator: ". "))
            }
        }
    }

    struct SavedOverTimeChart: View {
        let points: [OverviewCharts.SavedPoint]

        var body: some View {
            ChartBox(
                title: "Space Saved Over Time", subtitle: "Total by the day videos were added",
                isEmpty: points.isEmpty, emptyText: "Appears after the first conversion finishes.",
                single: points.count == 1
                    ? (
                        ByteFormat.string(points[0].cumulativeBytes),
                        "saved on \(points[0].day.formatted(date: .abbreviated, time: .omitted))"
                    ) : nil
            ) {
                Chart(points) { point in
                    AreaMark(x: .value("Day", point.day, unit: .day), y: .value("Saved", point.cumulativeBytes))
                        .foregroundStyle(Color.green.opacity(0.22).gradient)
                    LineMark(x: .value("Day", point.day, unit: .day), y: .value("Saved", point.cumulativeBytes))
                        .foregroundStyle(Color.green)
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("Day", point.day, unit: .day), y: .value("Saved", point.cumulativeBytes))
                        .foregroundStyle(Color.green)
                        .accessibilityLabel(point.day.formatted(date: .abbreviated, time: .omitted))
                        .accessibilityValue("\(ByteFormat.string(point.cumulativeBytes)) saved in total")
                }
                .chartYAxis { byteAxisMarks(position: .leading) }
                .chartPlotStyle { $0.padding(.top, 10).padding(.horizontal, 8) }
                .accessibilityLabel("Total space saved by day")
                .accessibilityValue(
                    "\(ByteFormat.string(points.last?.cumulativeBytes ?? 0)) saved in total over "
                        + "\(points.count) \(points.count == 1 ? "day" : "days")")
            }
        }
    }

    struct ThroughputChart: View {
        let days: [OverviewCharts.DayThroughput]

        var body: some View {
            ChartBox(
                title: "Queue Throughput", subtitle: "Videos converted by day", isEmpty: days.isEmpty,
                emptyText: "Appears after the first conversion finishes.",
                single: days.count == 1
                    ? (
                        days[0].videos.formatted(),
                        (days[0].videos == 1 ? "video" : "videos")
                            + " converted on \(days[0].day.formatted(date: .abbreviated, time: .omitted))"
                    ) : nil
            ) {
                Chart(days) { day in
                    BarMark(x: .value("Day", day.day, unit: .day), y: .value("Videos", day.videos))
                        .foregroundStyle(Color.orange.gradient)
                        .cornerRadius(3)
                        .accessibilityLabel(day.day.formatted(date: .abbreviated, time: .omitted))
                        .accessibilityValue(day.videos == 1 ? "1 video converted" : "\(day.videos) videos converted")
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        if let count = value.as(Double.self), count == count.rounded() {
                            AxisGridLine()
                            AxisValueLabel(horizontalSpacing: 10) {
                                Text(Int(count), format: .number)
                            }
                        }
                    }
                }
                .chartPlotStyle { $0.padding(.top, 10).padding(.horizontal, 8) }
                .accessibilityLabel("Videos converted by day")
                .accessibilityValue(
                    "\(days.reduce(0) { $0 + $1.videos }) videos converted over "
                        + "\(days.count) \(days.count == 1 ? "day" : "days")")
            }
        }
    }

    /// A size axis with byte-formatted labels ("1.2 GB") instead of raw numbers.
    @AxisContentBuilder func byteAxisMarks(position: AxisMarkPosition = .bottom) -> some AxisContent {
        AxisMarks(position: position, values: .automatic(desiredCount: 3)) { value in
            AxisGridLine()
            AxisValueLabel(horizontalSpacing: 10, verticalSpacing: 6) {
                if let raw = value.as(Double.self) {
                    let bytes = Int64(raw.rounded())
                    Text(bytes == 0 ? "0" : ByteFormat.string(bytes))
                }
            }
        }
    }
#endif
