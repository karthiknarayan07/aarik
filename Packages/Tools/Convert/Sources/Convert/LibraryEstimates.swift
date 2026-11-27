import AppCore
import LocalLibrary
import MediaEngine

extension LibraryItem {
    /// How big the converted copy would be at `preset`, from the same estimate the Overview uses; nil when the
    /// video would be kept as it is.
    public func estimatedBytes(preset: Preset) -> Int64? {
        if isImage { return estimatedBytes(imageSpec: ImageSpec()) }
        let source = OverviewSummary.estimationSource(for: self)
        guard
            case .convert(_, let estimate, _) = SavingsCalculator.decision(
                byteSize: source.byteSize, inventory: source.inventory, preset: preset)
        else { return nil }
        return estimate
    }

    /// How big the converted image would be with `imageSpec`; nil when the image would be kept as is.
    public func estimatedBytes(imageSpec: ImageSpec) -> Int64? {
        guard isImage, pixelSize.width > 0, pixelSize.height > 0,
            case .convert(_, _, _, let estimate, _) = ImagePlanner.decide(
                byteSize: byteSize, pixelSize: pixelSize, sourceUTI: imageSourceUTI, inventory: inventory,
                spec: imageSpec, isLivePhoto: badges.contains(.livePhoto))
        else { return nil }
        return estimate
    }
}
