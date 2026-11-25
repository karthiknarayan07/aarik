import SwiftUI

/// An empty or no-selection state: an SF Symbol, a short title and one line of text.
public struct EmptyState: View {
    public let title: String
    public let systemImage: String
    public let message: String

    public init(_ title: String, systemImage: String, message: String) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
    }

    public var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        }
    }
}
