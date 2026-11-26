import SwiftUI

@main
struct MainApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// Placeholder root. The real iPhone and iPad shells replace it in later tasks.
struct RootView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "No Videos Yet",
                systemImage: "film.stack",
                description: Text("Videos you choose to shrink will appear here.")
            )
            .navigationTitle("Library")
        }
        .accessibilityIdentifier("root")
    }
}
