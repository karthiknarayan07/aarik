import Testing

@testable import AppUI

@MainActor
@Test func emptyStateKeepsItsContent() {
    let state = EmptyState("Queue is empty", systemImage: "list.bullet.rectangle", message: "Nothing to do.")
    #expect(state.title == "Queue is empty")
    #expect(state.systemImage == "list.bullet.rectangle")
    #expect(state.message == "Nothing to do.")
}
