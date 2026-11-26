import AppCore
import MediaEngine

/// A selected video as the inspector needs it: size, metadata, whether the file can be converted now, and the
/// preset it converts with (the header's, or its own override).
public struct InspectorSource: Sendable {
    public let byteSize: Int64
    public let inventory: MetadataInventory
    public let isAvailable: Bool
    public let preset: Preset

    public init(byteSize: Int64, inventory: MetadataInventory, isAvailable: Bool, preset: Preset) {
        self.byteSize = byteSize
        self.inventory = inventory
        self.isAvailable = isAvailable
        self.preset = preset
    }

    public var savings: SavingsCalculator.Source { (byteSize: byteSize, inventory: inventory) }
}

/// "Add to queue · Balanced" for one video, "Add 3 to queue" for several, "Nothing to add" for none.
public enum QueueButtonTitle {
    public static func title(count: Int, preset: Preset, isCustom: Bool) -> String {
        switch count {
        case ..<1: "Nothing to add"
        case 1: "Add to queue · \(isCustom ? "Custom" : preset.displayName)"
        default: "Add \(count) to queue"
        }
    }

    /// What the bar over the grid says while selecting: "3 Videos · Save 1.2 GB" (the saving is left out when
    /// unknown). The bar's buttons, Add to Queue and Convert Now, say what happens to them.
    public static func selectionSummary(count: Int, saved: String?) -> String {
        let noun = count == 1 ? "1 Video" : "\(count) Videos"
        guard let saved else { return noun }
        return "\(noun) · Save \(saved)"
    }

    /// The Queue's Start button: "Start" with what the waiting videos would save together, when known.
    public static func startTitle(saved: String?) -> String {
        guard let saved else { return "Start" }
        return "Start · Save \(saved)"
    }

    /// The toolbar button's title: short, in Title Case. "Add to Queue", or "Add 3 to Queue" for several.
    public static func toolbarTitle(count: Int) -> String {
        count > 1 ? "Add \(count) to Queue" : "Add to Queue"
    }
}
