import LocalLibrary
import SwiftUI

/// Segmented media-kind switcher (All / Videos / Images) shared at the top of Photos and Local Files screens.
struct MediaKindPicker: View {
    @Binding var selection: MediaKindFilter

    var body: some View {
        Picker("Show", selection: $selection) {
            ForEach(MediaKindFilter.allCases) { kind in
                Text(kind.title).tag(kind)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Media Type Filter")
        .accessibilityIdentifier("mediaKindPicker")
    }
}
