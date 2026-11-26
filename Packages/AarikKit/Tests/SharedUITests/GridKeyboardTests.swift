import Foundation
import Testing

@testable import SharedUI

@Suite struct GridKeyboardTests {
    private func resolve(
        _ key: GridKey, _ modifiers: GridKeyModifiers = [], typing: Bool = false
    ) -> GridKeyCommand? {
        GridKeyCommand.resolve(key, modifiers: modifiers, isTypeSelecting: typing)
    }

    @Test func arrowsMoveAndShiftExtends() {
        #expect(resolve(.arrow(.left)) == .move(.left, extend: false))
        #expect(resolve(.arrow(.down), .shift) == .move(.down, extend: true))
    }

    @Test func arrowsWithCommandOptionOrControlAreLeftToTheSystem() {
        #expect(resolve(.arrow(.up), .command) == nil)
        #expect(resolve(.arrow(.up), .option) == nil)
        #expect(resolve(.arrow(.up), .control) == nil)
    }

    @Test func homeAndEndJump() {
        #expect(resolve(.home) == .jump(toEnd: false, extend: false))
        #expect(resolve(.end, .shift) == .jump(toEnd: true, extend: true))
        #expect(resolve(.end, .command) == nil)
    }

    @Test func returnOpensButCommandReturnBelongsToTheQueueMenu() {
        #expect(resolve(.returnKey) == .open)
        #expect(resolve(.returnKey, .command) == nil)
        #expect(resolve(.returnKey, .shift) == nil)
    }

    @Test func spacePreviewsUnlessAWordIsBeingTyped() {
        #expect(resolve(.space) == .quickLook)
        #expect(resolve(.space, typing: true) == .typeSelect(" "))
        #expect(resolve(.space, .command) == nil)
    }

    @Test func printableCharactersTypeSelect() {
        #expect(resolve(.character("a")) == .typeSelect("a"))
        #expect(resolve(.character("A"), .shift) == .typeSelect("A"))
        #expect(resolve(.character("7")) == .typeSelect("7"))
    }

    @Test func commandAndControlShortcutsAreNotTypeSelect() {
        #expect(resolve(.character("a"), .command) == nil)
        #expect(resolve(.character("c"), .control) == nil)
    }

    @Test func controlAndFunctionKeyCharactersAreIgnored() {
        #expect(resolve(.character("\u{1B}")) == nil)
        #expect(resolve(.character("\u{F704}")) == nil)
        #expect(resolve(.character("")) == nil)
        #expect(resolve(.character("\r")) == nil)
    }
}

@Suite struct TypeSelectTests {
    private let names: [(id: Int, name: String)] = [
        (1, "Beach day.mov"), (2, "birthday.mp4"), (3, "Éclair.mov"), (4, "Hike.mov"),
    ]

    @Test func matchesTheFirstNameWithThePrefixIgnoringCase() {
        #expect(TypeSelectBuffer.match(prefix: "b", in: names) == 1)
        #expect(TypeSelectBuffer.match(prefix: "bi", in: names) == 2)
        #expect(TypeSelectBuffer.match(prefix: "BIRTH", in: names) == 2)
    }

    @Test func ignoresAccents() {
        #expect(TypeSelectBuffer.match(prefix: "ec", in: names) == 3)
    }

    @Test func noMatchOrEmptyPrefixSelectsNothing() {
        #expect(TypeSelectBuffer.match(prefix: "z", in: names) == nil)
        #expect(TypeSelectBuffer.match(prefix: "", in: names) == nil)
        #expect(TypeSelectBuffer.match(prefix: "ike", in: names) == nil)
    }

    @Test func lettersJoinUntilThePauseThenAWordStartsOver() {
        var buffer = TypeSelectBuffer()
        let start = Date(timeIntervalSince1970: 1000)
        #expect(buffer.append("b", at: start) == "b")
        #expect(buffer.append("i", at: start.addingTimeInterval(0.5)) == "bi")
        #expect(buffer.isTyping(at: start.addingTimeInterval(1.0)))
        // More than a second after the last key: a new word.
        #expect(buffer.append("h", at: start.addingTimeInterval(2.0)) == "h")
    }

    @Test func isTypingOnlyWithinTheTimeout() {
        var buffer = TypeSelectBuffer()
        let start = Date(timeIntervalSince1970: 1000)
        #expect(!buffer.isTyping(at: start))
        _ = buffer.append("a", at: start)
        #expect(buffer.isTyping(at: start.addingTimeInterval(0.9)))
        #expect(!buffer.isTyping(at: start.addingTimeInterval(1.1)))
        buffer.reset()
        #expect(!buffer.isTyping(at: start))
    }
}
