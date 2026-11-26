Task 3b WIP report (stopped on coordinator request, usage limit).
Done: commit 1 Tool core/scene protocols/queue register (builds, tests green); commit 2 AppServices+LibraryService+SettingsStore, StagedInputs/ThumbnailSource moved (builds); commit 3 git mv of AppModel/pages into Convert/ConvertUI.
In progress (WIP commit): ConvertModel written, Convert target compiles; ConvertUI/Mac pages moved with sed edits, still erroring (thumbnails->thumbnailSource, KeyChord.keyboardShortcut, showMainWindow via host).
Left: fix ConvertUI, write ConvertMacScene/ConvertIOSScene stub, MacShell composition root (replaces AppModel, pbxproj ok), persistedIdentifiersUnchanged type-based asserts, ADR 0004 pointer, tests move, verification x2, counts (baseline 605 Core + 413 Convert = 1018).
Builds: Core yes; Convert target yes, ConvertUI no, Mac app no.
