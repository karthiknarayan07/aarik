import SwiftUI

/// First-run welcome on Overview: the brand mark, one line on what the app does, and three plain promises about
/// what happens to the user's files. Actions are passed in, so the view knows nothing about the model.
struct WelcomeView: View {
    var allowPhotos: (() -> Void)?
    var useLocalFiles: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image("BrandMark")
                .resizable()
                .scaledToFit()
                .frame(height: 140)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("Welcome to \(AppModel.displayName)")
                    .font(.largeTitle.weight(.semibold))
                Text("Find the videos that take the most space and keep smaller copies that look the same.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            VStack(alignment: .leading, spacing: 10) {
                Label("Nothing changes until you add videos to the queue.", systemImage: "lock")
                Label("Copies keep the date, place, camera details and Dolby Vision.", systemImage: "checkmark.seal")
                Label(
                    "Originals go to the Trash or Recently Deleted only after a verified copy exists.",
                    systemImage: "arrow.uturn.backward.circle")
            }
            .font(.body)
            .padding(.top, 4)
            VStack(spacing: 10) {
                if let allowPhotos {
                    Button("Allow access to Photos…", action: allowPhotos)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    Button("Use local files instead", action: useLocalFiles)
                        .buttonStyle(.link)
                } else {
                    Button("Add videos…", action: useLocalFiles)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            }
            .padding(.top, 8)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    WelcomeView(allowPhotos: {}, useLocalFiles: {})
        .frame(width: 900, height: 640)
}
