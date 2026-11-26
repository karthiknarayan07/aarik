import Testing

@testable import AppUI

@Suite struct CommandModelTests {
    private let idle = AppCommandContext()
    private let busy = AppCommandContext(
        canRemoveFromLibrary: true, canAddToQueue: true, isQueuePaused: true, failedJobCount: 2)

    @Test func pauseIsNotOnCommandPeriodAndTheTitleFollowsTheState() {
        let running = AppCommands.command(.pauseOrResumeQueue, in: idle)
        let paused = AppCommands.command(.pauseOrResumeQueue, in: busy)

        #expect(running.title == "Pause Queue")
        #expect(paused.title == "Resume Queue")
        #expect(running.shortcut == KeyChord(.character("p"), [.command, .option]))
        #expect(running.shortcut != .command("."))
        #expect(running.isEnabled && paused.isEnabled)
    }

    @Test func commandsAreEnabledOnlyWhenTheyHaveSomethingToDo() {
        #expect(!AppCommands.command(.removeFromLibrary, in: idle).isEnabled)
        #expect(AppCommands.command(.removeFromLibrary, in: busy).isEnabled)
        #expect(!AppCommands.command(.addToQueue, in: idle).isEnabled)
        #expect(AppCommands.command(.addToQueue, in: busy).isEnabled)
        #expect(!AppCommands.command(.retryAllFailed, in: idle).isEnabled)
        #expect(AppCommands.command(.retryAllFailed, in: busy).isEnabled)
        #expect(AppCommands.command(.addVideos, in: idle).isEnabled)
    }

    @Test func removeFromLibraryHasNoChordSoTextFieldsKeepCommandDelete() {
        #expect(AppCommands.command(.removeFromLibrary, in: idle).shortcut == nil)
        #expect(AppCommands.command(.addToQueue, in: idle).shortcut == KeyChord(.return, .command))
        #expect(AppCommands.command(.addVideos, in: idle).shortcut == .command("o"))
    }

    @Test func newChatIsCommandNOnlyWhileAskShows() {
        let asking = AppCommandContext(canStartNewChat: true)
        let command = AppCommands.command(.newChat, in: asking)
        #expect(command.title == "New Chat")
        #expect(command.shortcut == .command("n"))
        #expect(command.isEnabled)
        #expect(!AppCommands.command(.newChat, in: idle).isEnabled)
        #expect(!AppCommands.reservedChords.contains(.command("n")))
        // Every other command keeps its own chord, so ⌘N is used once.
        let others = AppCommands.all(in: busy).filter { $0.id != .newChat }.compactMap(\.shortcut)
        #expect(!others.contains(.command("n")))
    }

    @Test func composerReturnSendsAndShiftReturnAddsALine() {
        typealias Key = ComposerKey
        #expect(Key.return(shift: false, option: false, hasText: true, isGenerating: false) == .send)
        #expect(Key.return(shift: true, option: false, hasText: true, isGenerating: false) == .newline)
        #expect(Key.return(shift: false, option: true, hasText: true, isGenerating: false) == .newline)
        #expect(Key.return(shift: false, option: false, hasText: false, isGenerating: false) == .ignoreReturn)
        #expect(Key.return(shift: false, option: false, hasText: true, isGenerating: true) == .ignoreReturn)
        #expect(
            Key.return(shift: false, option: false, hasText: true, isGenerating: false, isComposing: true)
                == .passThrough)
    }

    @Test func escapeStopsOnlyWhileAnAnswerIsBeingWritten() {
        #expect(ComposerKey.escape(isGenerating: true) == .stop)
        #expect(ComposerKey.escape(isGenerating: false) == .passThrough)
    }

    @Test func everyCommandHasAUniqueShortcutThatTheSystemDoesNotOwn() {
        for context in [idle, busy] {
            let chords = AppCommands.all(in: context).compactMap(\.shortcut)
            #expect(Set(chords).count == chords.count)
            for chord in chords { #expect(!AppCommands.reservedChords.contains(chord)) }
        }
    }

    @Test func sectionShortcutsClashWithNeitherCommandsNorTheSystem() {
        let sections = (0..<9).compactMap(SectionShortcuts.chord(at:))
        let commands = AppCommands.all(in: busy).compactMap(\.shortcut)

        #expect(sections.count == 9)
        #expect(Set(sections).count == 9)
        #expect(Set(sections).isDisjoint(with: commands))
        #expect(Set(sections).isDisjoint(with: AppCommands.reservedChords))
    }

    @Test func sectionShortcutsRunFromCommandOneToCommandNine() {
        #expect(SectionShortcuts.chord(at: 0) == .command("1"))
        #expect(SectionShortcuts.chord(at: 6) == .command("7"))
        #expect(SectionShortcuts.chord(at: 8) == .command("9"))
        #expect(SectionShortcuts.chord(at: 9) == nil)
        #expect(SectionShortcuts.chord(at: -1) == nil)
    }

    @Test func titlesAreTitleCaseAndOnlyInputCommandsEndInAnEllipsis() {
        let small: Set<String> = ["a", "an", "the", "of", "to", "in", "on", "and", "or", "for", "from"]
        for command in AppCommands.all(in: busy) + AppCommands.all(in: idle) {
            let words = command.title.replacing("…", with: "").split(separator: " ")
            for (index, word) in words.enumerated() where index == 0 || !small.contains(word.lowercased()) {
                #expect(word.first?.isUppercase == true, "\(command.title)")
            }
        }
        #expect(AppCommands.command(.addVideos, in: idle).title.hasSuffix("…"))
        #expect(!AppCommands.command(.addToQueue, in: idle).title.hasSuffix("…"))
    }
}
