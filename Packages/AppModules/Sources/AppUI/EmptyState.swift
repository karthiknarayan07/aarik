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

/// A first-run state: an SF Symbol, a title, a few short lines, and actions.
public struct WelcomeState<Actions: View>: View {
    public let title: String
    public let systemImage: String
    public let lines: [String]
    let actions: Actions

    public init(_ title: String, systemImage: String, lines: [String], @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.systemImage = systemImage
        self.lines = lines
        self.actions = actions()
    }

    public var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            VStack(spacing: 4) {
                ForEach(lines, id: \.self) { Text($0) }
            }
        } actions: {
            actions
        }
    }
}
