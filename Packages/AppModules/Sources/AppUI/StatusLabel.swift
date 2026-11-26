import SwiftUI

/// A status line as Apple's apps draw it: the colour is on the symbol only, and the text stays in the standard
/// secondary colour so it keeps its contrast (Increase Contrast included).
public struct StatusLabel: View {
    let title: String
    let systemImage: String
    let tint: Color

    public init(_ title: String, systemImage: String, tint: Color) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
    }

    public var body: some View {
        Label {
            Text(title).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
    }
}
