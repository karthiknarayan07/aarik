import SwiftUI
import WidgetKit

struct PlaceholderEntry: TimelineEntry {
    let date: Date
}

struct PlaceholderProvider: TimelineProvider {
    func placeholder(in context: Context) -> PlaceholderEntry { PlaceholderEntry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (PlaceholderEntry) -> Void) {
        completion(PlaceholderEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<PlaceholderEntry>) -> Void) {
        completion(Timeline(entries: [PlaceholderEntry(date: .now)], policy: .never))
    }
}

/// Placeholder home screen widget. The real queue summary replaces it in a later task.
struct PlaceholderWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PlaceholderWidget", provider: PlaceholderProvider()) { _ in
            Label("Shrink Queue", systemImage: "film.stack")
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Shrink Queue")
        .description("Shows the progress of your shrink queue.")
        .supportedFamilies([.systemSmall])
    }
}
