import Testing

@testable import AppUI

@Suite struct GridSelectionTests {
    // Two sections: a full row plus one (columns = 3), then a section of two.
    private let sections = [["a", "b", "c", "d"], ["e", "f"]]

    @Test func plainClickSelectsOnlyThatItem() {
        var selection = GridSelection<String>(selected: ["a", "b"])
        selection.click("c", modifiers: [], sections: sections)
        #expect(selection.selected == ["c"])
        #expect(selection.focus == "c")
    }

    @Test func commandClickToggles() {
        var selection = GridSelection<String>(selected: ["a"])
        selection.click("c", modifiers: .toggle, sections: sections)
        #expect(selection.selected == ["a", "c"])
        selection.click("a", modifiers: .toggle, sections: sections)
        #expect(selection.selected == ["c"])
    }

    @Test func shiftClickSelectsTheRangeFromTheAnchorAcrossSections() {
        var selection = GridSelection<String>()
        selection.click("c", modifiers: [], sections: sections)
        selection.click("e", modifiers: .extend, sections: sections)
        #expect(selection.selected == ["c", "d", "e"])
        selection.click("a", modifiers: .extend, sections: sections)
        #expect(selection.selected == ["a", "b", "c"])
    }

    @Test func selectAllSelectsEveryItemInEverySection() {
        var selection = GridSelection<String>(selected: ["b"])
        selection.selectAll(sections: sections)
        #expect(selection.selected == ["a", "b", "c", "d", "e", "f"])
        var empty = GridSelection<String>(selected: ["x"])
        empty.selectAll(sections: [])
        #expect(empty.selected == ["x"])
    }

    @Test func arrowsMoveWithinRowsAndAcrossSections() {
        var selection = GridSelection<String>()
        selection.move(.right, sections: sections, columns: 3)
        #expect(selection.selected == ["a"])
        selection.move(.right, sections: sections, columns: 3)
        #expect(selection.selected == ["b"])
        selection.move(.down, sections: sections, columns: 3)
        // Row 2 of the first section has only "d"; down from "b" lands on the last item of that row.
        #expect(selection.selected == ["d"])
        selection.move(.down, sections: sections, columns: 3)
        #expect(selection.selected == ["e"])
        selection.move(.up, sections: sections, columns: 3)
        #expect(selection.selected == ["d"])
        selection.move(.up, sections: sections, columns: 3)
        #expect(selection.selected == ["a"])
        selection.move(.left, sections: sections, columns: 3)
        #expect(selection.selected == ["a"])
    }

    @Test func rightFromTheLastItemStays() {
        var selection = GridSelection<String>()
        selection.click("f", modifiers: [], sections: sections)
        selection.move(.right, sections: sections, columns: 3)
        #expect(selection.selected == ["f"])
        selection.move(.down, sections: sections, columns: 3)
        #expect(selection.selected == ["f"])
    }

    @Test func byteFormatShowsFileSizesAndSavings() {
        #expect(ByteFormat.string(0) == Int64(0).formatted(.byteCount(style: .file)))
        #expect(ByteFormat.savedPercent(before: 1000, after: 520) == "\u{2212}48%")
        #expect(ByteFormat.savedPercent(before: 0, after: 0) == nil)
    }
}

/// A tile's context menu acts on the selection when the tile is part of it, else on that tile alone.
@Test func contextMenuActsOnTheSelectionOnlyWhenTheClickedTileIsInIt() {
    #expect(ContextMenuTargets.ids(clicked: 2, selection: [1, 2, 3]) == [1, 2, 3])
    #expect(ContextMenuTargets.ids(clicked: 4, selection: [1, 2, 3]) == [4])
    #expect(ContextMenuTargets.ids(clicked: 4, selection: []) == [4])
}
