import Testing

@testable import Convert

/// The inspector's preset control: a real Mixed state, and no preset choice while custom settings apply to all.
@Suite struct PresetControlTests {
    @Test func aSharedPresetIsSelectedAndChoosable() {
        let control = PresetControl(shared: .balanced, isCustom: false)

        #expect(control.options == Preset.allCases.map(PresetControl.Choice.preset))
        #expect(control.selection == .preset(.balanced))
        #expect(control.isEnabled)
        #expect(control.preset(choosing: .preset(.smaller)) == .smaller)
    }

    @Test func aMixedSelectionShowsMixedAsItsOwnOption() {
        let control = PresetControl(shared: nil, isCustom: false)

        #expect(control.options == [.mixed] + Preset.allCases.map(PresetControl.Choice.preset))
        #expect(control.selection == .mixed)
        #expect(PresetControl.label(.mixed) == "Mixed")
        #expect(PresetControl.label(.preset(.high)) == "High")
        // Choosing Mixed itself changes nothing; choosing a preset applies it to the whole selection.
        #expect(control.preset(choosing: .mixed) == nil)
        #expect(control.preset(choosing: .preset(.high)) == .high)
    }

    /// Custom settings apply to every video, so a per-video preset choice can't turn them off for the others.
    @Test func customSettingsDisableThePresetChoice() {
        let control = PresetControl(shared: .smaller, isCustom: true)

        #expect(!control.isEnabled)
        #expect(control.preset(choosing: .preset(.high)) == nil)
        #expect(control.help.contains("custom settings"))
    }
}
