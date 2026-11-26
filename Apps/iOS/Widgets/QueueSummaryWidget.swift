import AppCore
import SwiftUI
import WidgetKit

struct QueueSummaryEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct QueueSummaryProvider: TimelineProvider {
    private static let previewSnapshot = WidgetSnapshot(
        savedBytes: 2_400_000_000,
        queueCount: 3,
        completedCount: 8,
        isPaused: false
    )

    func placeholder(in context: Context) -> QueueSummaryEntry {
        QueueSummaryEntry(date: .now, snapshot: Self.previewSnapshot)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (QueueSummaryEntry) -> Void) {
        let stored = WidgetSnapshotStore()?.load()
        let snapshot = stored ?? (context.isPreview ? Self.previewSnapshot : .empty)
        completion(QueueSummaryEntry(date: .now, snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<QueueSummaryEntry>) -> Void) {
        let snapshot = WidgetSnapshotStore()?.loadOrEmpty() ?? .empty
        let entry = QueueSummaryEntry(date: .now, snapshot: snapshot)
        completion(Timeline(entries: [entry], policy: .never))
    }
}

struct QueueSummaryWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WidgetSnapshot

    private var savedText: String {
        snapshot.savedBytes > 0 ? snapshot.savedBytes.formatted(.byteCount(style: .file)) : "0 MB"
    }

    private var queueSummaryText: String {
        if snapshot.isPaused {
            return snapshot.queueCount > 0 ? "Paused · \(snapshot.queueCount) queued" : "Paused"
        }
        switch snapshot.queueCount {
        case 0: return "Queue empty"
        case 1: return "1 video in queue"
        default: return "\(snapshot.queueCount) videos in queue"
        }
    }

    private var completedText: String {
        switch snapshot.completedCount {
        case 0: return "No videos shrunk yet"
        case 1: return "1 video shrunk"
        default: return "\(snapshot.completedCount) videos shrunk"
        }
    }

    private var statusTitle: String {
        if snapshot.isPaused { return "Paused" }
        return snapshot.queueCount > 0 ? "Queue" : "Idle"
    }

    private var statusSymbol: String {
        if snapshot.isPaused { return "pause.circle.fill" }
        return snapshot.queueCount > 0 ? "film.stack" : "checkmark.circle"
    }

    var body: some View {
        Group {
            switch family {
            case .systemMedium:
                mediumBody
            default:
                smallBody
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private var smallBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Space Saved", systemImage: snapshot.isPaused ? "pause.circle.fill" : "film.stack")
                .font(.caption.weight(.semibold))
                .foregroundStyle(snapshot.isPaused ? Color.orange : Color.secondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            Text(savedText)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(queueSummaryText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var mediumBody: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Space Saved", systemImage: "film.stack")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(savedText)
                    .font(.title.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text(completedText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 4) {
                Label(statusTitle, systemImage: statusSymbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(snapshot.isPaused ? Color.orange : Color.accentColor)
                    .lineLimit(1)

                Text("\(snapshot.queueCount)")
                    .font(.title.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)

                Text("In Queue")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var accessibilityDescription: String {
        let queuePart =
            snapshot.queueCount == 1 ? "1 video in queue" : "\(snapshot.queueCount) videos in queue"
        let pausePart = snapshot.isPaused ? ", paused" : ""
        return "Space saved \(savedText), \(queuePart)\(pausePart)."
    }
}

/// Home Screen widget showing total space saved and current queue count from the App Group snapshot.
struct QueueSummaryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKinds.summary, provider: QueueSummaryProvider()) { entry in
            QueueSummaryWidgetView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Shrink Queue")
        .description("Shows space saved and the current queue count.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
