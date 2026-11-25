import Foundation

/// The Dolby Vision decoder configuration carried in a `dvcC`, `dvvC` or `dvwC` sample description atom.
public struct DolbyVisionConfig: Equatable, Sendable {
    public let profile: Int
    public let level: Int
    public let rpuPresent: Bool
    public let elPresent: Bool
    public let blPresent: Bool
    public let compatibilityID: Int

    /// Parses the body of a `dvcC`/`dvvC`/`dvwC` atom (big-endian). Returns nil if shorter than 5 bytes.
    public init?(record: Data) {
        guard record.count >= 5 else { return nil }
        let bytes = [UInt8](record.prefix(5))
        // bytes[0], bytes[1]: version major / minor.
        let word = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        profile = Int(word >> 9)
        level = Int((word >> 3) & 0x3F)
        rpuPresent = word & 0x4 != 0
        elPresent = word & 0x2 != 0
        blPresent = word & 0x1 != 0
        compatibilityID = Int(bytes[4] >> 4)
    }

    /// For example `"profile 8, level 9, compat 4"`.
    public var displayValue: String {
        "profile \(profile), level \(level), compat \(compatibilityID)"
    }
}
