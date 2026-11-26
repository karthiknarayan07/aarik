import CoreGraphics
import Foundation
import Testing

@testable import AppUI

@Suite struct GridInteractionTests {
    // Two rows of two tiles, 100 wide with 10 between: a/b on the first row, c/d on the second.
    private let frames: [String: CGRect] = [
        "a": CGRect(x: 0, y: 0, width: 100, height: 100), "b": CGRect(x: 110, y: 0, width: 100, height: 100),
        "c": CGRect(x: 0, y: 110, width: 100, height: 100), "d": CGRect(x: 110, y: 110, width: 100, height: 100),
    ]

    // MARK: Marquee

    @Test func marqueeRectIsNormalisedForAnyDragDirection() {
        let rect = MarqueeSelection.rect(from: CGPoint(x: 50, y: 80), to: CGPoint(x: 10, y: 20))
        #expect(rect == CGRect(x: 10, y: 20, width: 40, height: 60))
    }

    @Test func marqueeSelectsEveryTileItTouches() {
        let rect = CGRect(x: 90, y: 90, width: 30, height: 30)
        let selected = MarqueeSelection.selection(rect: rect, frames: frames, base: [], mode: .replace)
        #expect(selected == ["a", "b", "c", "d"])
        let narrow = CGRect(x: 120, y: 10, width: 20, height: 20)
        #expect(MarqueeSelection.selection(rect: narrow, frames: frames, base: ["a"], mode: .replace) == ["b"])
    }

    @Test func shiftMarqueeAddsAndCommandMarqueeToggles() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(MarqueeSelection.selection(rect: rect, frames: frames, base: ["d"], mode: .add) == ["a", "d"])
        #expect(
            MarqueeSelection.selection(rect: rect, frames: frames, base: ["a", "d"], mode: .toggle) == ["d"])
        #expect(MarqueeSelection.selection(rect: rect, frames: frames, base: ["d"], mode: .toggle) == ["a", "d"])
    }

    @Test func marqueeOnlyStartsOnEmptySpace() {
        #expect(!MarqueeSelection.startsOnEmptySpace(CGPoint(x: 50, y: 50), frames: frames))
        // The gap between tiles, and the margin, are empty.
        #expect(MarqueeSelection.startsOnEmptySpace(CGPoint(x: 105, y: 50), frames: frames))
        #expect(MarqueeSelection.startsOnEmptySpace(CGPoint(x: -8, y: 50), frames: frames))
        #expect(MarqueeSelection.startsOnEmptySpace(CGPoint(x: 50, y: 500), frames: frames))
    }

    @Test func aSmallMovementIsAClickNotAMarquee() {
        #expect(!MarqueeSelection.isDrag(from: .zero, to: CGPoint(x: 2, y: 2)))
        #expect(MarqueeSelection.isDrag(from: .zero, to: CGPoint(x: 4, y: 0)))
    }

    // MARK: Selection appearance

    @Test func selectionIsGreyUnlessTheWindowIsActiveAndTheGridHasFocus() {
        #expect(SelectionEmphasis.resolve(isWindowActive: true, isGridFocused: true) == .emphasized)
        #expect(SelectionEmphasis.resolve(isWindowActive: false, isGridFocused: true) == .unemphasized)
        #expect(SelectionEmphasis.resolve(isWindowActive: true, isGridFocused: false) == .unemphasized)
        #expect(SelectionEmphasis.resolve(isWindowActive: false, isGridFocused: false) == .unemphasized)
    }

    // MARK: Drag out

    @Test func draggingGivesTheSystemsTilesInGridOrderWithTheirFiles() {
        let urls = [
            "a": URL(filePath: "/v/a.mov"), "b": URL(filePath: "/v/b.mov"), "c": URL(filePath: "/v/c.mov"),
        ]
        let entries = MediaDragPayload.entries(ids: ["c", "a"], gridOrder: ["a", "b", "c"], url: { urls[$0] })
        #expect(entries.map(\.id) == ["a", "c"])
        #expect(entries.map(\.url.lastPathComponent) == ["a.mov", "c.mov"])
    }

    @Test func aTileWithoutAFileIsLeftOutOfTheDrag() {
        let urls = ["a": URL(filePath: "/v/a.mov")]
        let entries = MediaDragPayload.entries(ids: ["a", "b"], gridOrder: ["a", "b"], url: { urls[$0] })
        #expect(entries.map(\.id) == ["a"])
        #expect(MediaDragPayload.entries(ids: ["b"], gridOrder: ["a", "b"], url: { urls[$0] }).isEmpty)
    }

    // MARK: Open

    @Test func opensAtMostAFewVideosAtOnce() {
        #expect(OpenLimit.allows(1))
        #expect(OpenLimit.allows(OpenLimit.maximum))
        #expect(!OpenLimit.allows(OpenLimit.maximum + 1))
    }

    // MARK: Subtitle

    @Test func subtitleSaysWhatIsShown() {
        let text = LibrarySubtitle.text(
            shownCount: 3, shownBytes: 3_000_000_000, totalCount: 3, selectedCount: 0, selectedBytes: 0)
        #expect(text == VideoCount.summary(count: 3, bytes: 3_000_000_000))
    }

    @Test func subtitleSaysHowManyOfTheCollectionAFilterLeaves() {
        let text = LibrarySubtitle.text(
            shownCount: 218, shownBytes: 29_800_000_000, totalCount: 1203, selectedCount: 0, selectedBytes: 0)
        #expect(text.hasPrefix("218 of 1,203 videos · "))
        #expect(text.contains(ByteFormat.string(29_800_000_000)))
    }

    @Test func subtitleAddsTheSelectionAndWhatIsStillBeingRead() {
        let text = LibrarySubtitle.text(
            shownCount: 2, shownBytes: 2_000_000_000, totalCount: 2, selectedCount: 1, selectedBytes: 1_000_000_000,
            activity: "Scanning…")
        #expect(text.contains("1 selected, \(ByteFormat.string(1_000_000_000))"))
        #expect(text.hasSuffix(" · Scanning…"))
    }

    @Test func subtitleIsEmptyForAnEmptyLibrary() {
        #expect(
            LibrarySubtitle.text(shownCount: 0, shownBytes: 0, totalCount: 0, selectedCount: 0, selectedBytes: 0)
                .isEmpty)
    }

    @Test func subtitleWithNothingLeftByAFilterStillCountsTheCollection() {
        let text = LibrarySubtitle.text(
            shownCount: 0, shownBytes: 0, totalCount: 5, selectedCount: 0, selectedBytes: 0)
        #expect(text == "0 of 5 videos")
    }
}
