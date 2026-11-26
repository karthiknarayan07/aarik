import AppCore
import LocalLibrary

extension LibraryItem {
    /// How big the converted copy would be at `preset`, from the same estimate the Overview uses; nil when the
    /// video would be kept as it is.
    public func estimatedBytes(preset: Preset) -> Int64? {
        let source = OverviewSummary.estimationSource(for: self)
        guard
            case .convert(_, let estimate, _) = SavingsCalculator.decision(
                byteSize: source.byteSize, inventory: source.inventory, preset: preset)
        else { return nil }
        return estimate
    }
}
