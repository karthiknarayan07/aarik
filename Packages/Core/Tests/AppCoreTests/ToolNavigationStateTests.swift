import Testing

@testable import AppCore

@Suite struct ToolNavigationStateTests {
    @Test func roundTripsThroughItsStoredString() {
        let state = ToolNavigationState(toolID: "convert", page: "photos", column: .detail)
        #expect(ToolNavigationState(stored: state.stored) == state)
    }

    @Test func aMissingToolOrPageStaysMissing() {
        let state = ToolNavigationState(toolID: nil, page: nil, column: .tools)
        #expect(ToolNavigationState(stored: state.stored) == state)
    }

    @Test func anUnreadableStringFallsBackToTheToolsList() {
        #expect(ToolNavigationState(stored: "") == ToolNavigationState())
        #expect(ToolNavigationState(stored: "a|b") == ToolNavigationState())
        #expect(
            ToolNavigationState(stored: "convert|files|sideways")
                == ToolNavigationState(toolID: "convert", page: "files"))
    }

    @Test func aToolThatIsNotOfferedIsDropped() {
        let state = ToolNavigationState(toolID: "mac-only", page: "x", column: .pages)
        #expect(state.restricted(to: ["convert"]) == ToolNavigationState())
        #expect(state.restricted(to: ["mac-only"]) == state)
    }
}
