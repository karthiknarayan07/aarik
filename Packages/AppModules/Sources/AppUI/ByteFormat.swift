import Foundation

/// File sizes and savings as the app shows them.
public enum ByteFormat {
    /// "1.2 GB", using the system's file-size style.
    public static func string(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }

    /// "−48%" for the share saved; nil when there is nothing to compare.
    public static func savedPercent(before: Int64, after: Int64) -> String? {
        guard before > 0 else { return nil }
        let percent = Int((Double(before - after) / Double(before) * 100).rounded())
        return percent >= 0 ? "\u{2212}\(percent)%" : "+\(-percent)%"
    }
}
