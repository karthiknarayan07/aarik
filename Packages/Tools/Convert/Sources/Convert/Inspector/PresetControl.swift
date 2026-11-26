/// What the inspector's preset control shows and accepts for a selection.
///
/// A selection whose videos use different presets shows Mixed as an option of its own, so the control always has
/// a valid selection. While custom settings are on they apply to every video, so the preset choice is disabled
/// rather than turning custom settings off for videos that aren't selected.
struct PresetControl: Equatable {
    enum Choice: Hashable {
        case preset(Preset)
        case mixed
    }

    /// The preset every selected video uses; nil when they differ.
    let shared: Preset?
    /// Custom settings (Advanced) are on.
    let isCustom: Bool

    var options: [Choice] {
        (shared == nil ? [.mixed] : []) + Preset.allCases.map(Choice.preset)
    }

    var selection: Choice { shared.map(Choice.preset) ?? .mixed }

    var isEnabled: Bool { !isCustom }

    var help: String {
        isCustom
            ? "The custom settings in Advanced apply to every video; turn them off there to choose a preset"
            : "Choose the quality preset for the selected videos"
    }

    /// The preset to give the selection when `choice` is picked; nil when nothing changes (Mixed itself, or custom
    /// settings are on).
    func preset(choosing choice: Choice) -> Preset? {
        guard !isCustom, case .preset(let preset) = choice else { return nil }
        return preset
    }

    static func label(_ choice: Choice) -> String {
        switch choice {
        case .preset(let preset): preset.displayName
        case .mixed: "Mixed"
        }
    }
}
