import SwiftUI

/// An empty or no-selection state: an SF Symbol, a short title, one line of text, and at most one action.
public struct EmptyState: View {
    public let title: String
    public let systemImage: String
    public let message: String
    /// The action's button title; nil for no action.
    public private(set) var actionTitle: String?
    private var perform: (() -> Void)?

    public init(_ title: String, systemImage: String, message: String) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
    }

    /// The same state with a button that runs `perform`, such as a way to where the user can start.
    public func action(_ title: String, perform: @escaping () -> Void) -> EmptyState {
        var state = self
        state.actionTitle = title
        state.perform = perform
        return state
    }

    func performAction() {
        perform?()
    }

    public var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            if let actionTitle {
                Button(actionTitle, action: performAction)
            }
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
