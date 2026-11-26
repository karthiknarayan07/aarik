import Foundation

/// The window subtitle of a library page, as Photos writes "1,234 Photos": what is shown, how much it holds, what is
/// selected, and what is still being read. Replaces the status line under the grid.
public enum LibrarySubtitle {
    public static func text(
        shownCount: Int, shownBytes: Int64, totalCount: Int, selectedCount: Int, selectedBytes: Int64,
        activity: String? = nil
    ) -> String {
        var parts: [String] = []
        if totalCount > 0 {
            if shownCount < totalCount {
                let total = totalCount.formatted()
                let shown = shownCount.formatted()
                let noun = totalCount == 1 ? "video" : "videos"
                parts.append("\(shown) of \(total) \(noun)")
                if shownCount > 0 { parts.append(ByteFormat.string(shownBytes)) }
            } else {
                parts.append(VideoCount.summary(count: shownCount, bytes: shownBytes))
            }
        }
        if selectedCount > 0 {
            parts.append("\(selectedCount.formatted()) selected, \(ByteFormat.string(selectedBytes))")
        }
        if let activity { parts.append(activity) }
        return parts.joined(separator: " · ")
    }
}
