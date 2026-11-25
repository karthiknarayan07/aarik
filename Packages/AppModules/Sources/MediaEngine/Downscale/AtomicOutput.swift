import Darwin
import Foundation

/// Writes land in a hidden sibling of the final path and appear at the final path only through an exclusive rename,
/// so a half-written file is never visible there and a file someone else created is never replaced.
enum AtomicOutput {
    /// `.<final name>.partial-<UUID>` in the same directory (same volume, so the rename is atomic).
    static func partialURL(for final: URL) -> URL {
        final.deletingLastPathComponent().appending(path: ".\(final.lastPathComponent).partial-\(UUID().uuidString)")
    }

    /// Moves `partial` to `final` unless `final` exists. On any failure the partial is removed.
    static func commit(partial: URL, to final: URL) throws {
        if renamex_np(partial.path, final.path, UInt32(RENAME_EXCL)) == 0 { return }
        let code = errno
        try? FileManager.default.removeItem(at: partial)
        if code == EEXIST { throw DownscaleError.outputExists }
        throw DownscaleError.encoderFailed("could not move the finished file into place (errno \(code))")
    }
}
