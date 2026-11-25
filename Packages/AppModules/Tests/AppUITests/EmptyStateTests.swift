import Testing

@testable import AppUI

@MainActor
@Test func emptyStateKeepsItsContent() {
    let state = EmptyState("Queue is empty", systemImage: "list.bullet.rectangle", message: "Nothing to do.")
    #expect(state.title == "Queue is empty")
    #expect(state.systemImage == "list.bullet.rectangle")
    #expect(state.message == "Nothing to do.")
    #expect(state.actionTitle == nil)
}

@MainActor
@Test func emptyStateCanOfferOneAction() {
    var tapped = 0
    let state = EmptyState("Queue is empty", systemImage: "list.bullet.rectangle", message: "Nothing to do.")
        .action("Go to Local files") { tapped += 1 }

    #expect(state.title == "Queue is empty")
    #expect(state.message == "Nothing to do.")
    #expect(state.actionTitle == "Go to Local files")
    state.performAction()
    #expect(tapped == 1)
}
