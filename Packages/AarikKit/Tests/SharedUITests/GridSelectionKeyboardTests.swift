import Testing

@testable import AppUI

@Suite struct GridSelectionKeyboardTests {
    // Two sections, three columns: a b c / d, then e f.
    private let sections = [["a", "b", "c", "d"], ["e", "f"]]

    @Test func shiftRightExtendsTheRangeFromTheAnchor() {
        var selection = GridSelection<String>()
        selection.click("b", modifiers: [], sections: sections)
        selection.extend(.right, sections: sections, columns: 3)
        #expect(selection.selected == ["b", "c"])
        selection.extend(.right, sections: sections, columns: 3)
        #expect(selection.selected == ["b", "c", "d"])
        #expect(selection.focus == "d")
        #expect(selection.anchor == "b")
    }

    @Test func shiftArrowBackTowardsTheAnchorShrinksTheRange() {
        var selection = GridSelection<String>()
        selection.click("b", modifiers: [], sections: sections)
        selection.extend(.right, sections: sections, columns: 3)
        selection.extend(.right, sections: sections, columns: 3)
        selection.extend(.left, sections: sections, columns: 3)
        #expect(selection.selected == ["b", "c"])
    }

    @Test func shiftArrowCanCrossTheAnchorAndSectionBoundaries() {
        var selection = GridSelection<String>()
        selection.click("d", modifiers: [], sections: sections)
        selection.extend(.down, sections: sections, columns: 3)
        #expect(selection.selected == ["d", "e"])
        selection.extend(.up, sections: sections, columns: 3)
        selection.extend(.up, sections: sections, columns: 3)
        #expect(selection.selected == ["a", "b", "c", "d"])
    }

    @Test func shiftArrowAtAnEdgeKeepsTheRange() {
        var selection = GridSelection<String>()
        selection.click("f", modifiers: [], sections: sections)
        selection.extend(.right, sections: sections, columns: 3)
        #expect(selection.selected == ["f"])
    }

    @Test func homeAndEndJump() {
        var selection = GridSelection<String>()
        selection.click("c", modifiers: [], sections: sections)
        selection.jump(toEnd: true, extend: false, sections: sections)
        #expect(selection.selected == ["f"])
        selection.jump(toEnd: false, extend: false, sections: sections)
        #expect(selection.selected == ["a"])
    }

    @Test func shiftHomeAndEndSelectTheRangeFromTheAnchor() {
        var selection = GridSelection<String>()
        selection.click("c", modifiers: [], sections: sections)
        selection.jump(toEnd: true, extend: true, sections: sections)
        #expect(selection.selected == ["c", "d", "e", "f"])
        selection.jump(toEnd: false, extend: true, sections: sections)
        #expect(selection.selected == ["a", "b", "c"])
    }

    @Test func jumpInAnEmptyGridDoesNothing() {
        var selection = GridSelection<String>(selected: ["x"])
        selection.jump(toEnd: true, extend: false, sections: [])
        #expect(selection.selected == ["x"])
    }

    @Test func selectMakesOneItemTheSelectionFocusAndAnchor() {
        var selection = GridSelection<String>(selected: ["a", "b"])
        selection.select("e")
        #expect(selection.selected == ["e"])
        #expect(selection.focus == "e")
        #expect(selection.anchor == "e")
    }

    @Test func doubleClickOpensAndModifiedClicksSelect() {
        #expect(GridClickIntent.resolve(clickCount: 1, modifiers: []) == .select([]))
        #expect(GridClickIntent.resolve(clickCount: 2, modifiers: []) == .open)
        #expect(GridClickIntent.resolve(clickCount: 3, modifiers: []) == .open)
        #expect(GridClickIntent.resolve(clickCount: 2, modifiers: .toggle) == .select(.toggle))
        #expect(GridClickIntent.resolve(clickCount: 2, modifiers: .extend) == .select(.extend))
    }
}
