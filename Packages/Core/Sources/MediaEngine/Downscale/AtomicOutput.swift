import Darwin
import Foundation

/// Writes land in a hidden sibling of the final path and appear at the final path only through an exclusive rename,
/// so a half-written file is never visible there and a file someone else created is never replaced.
public enum AtomicOutput {
    /// `.<final name>.partial-<UUID>` in the same directory (same volume, so the rename is atomic).
    static func partialURL(for final: URL) -> URL {
        final.deletingLastPathComponent().appending(path: ".\(final.lastPathComponent).partial-\(UUID().uuidString)")
    }

    /// Renames `source` to `destination` only if nothing exists there, falling back to an exclusive create plus
    /// rename on volumes without `RENAME_EXCL`. Unlike `commit`, it never deletes `source`: on any failure both
    /// files are left as they were (a fallback placeholder it created is removed).
    public static func moveWithoutReplacing(_ source: URL, to destination: URL) throws {
        if renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return }
        let code = errno
        guard code == ENOTSUP || code == EINVAL else { throw posixError(code) }
        let fd = open(destination.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        guard fd >= 0 else { throw posixError(errno) }
        close(fd)
        if rename(source.path, destination.path) != 0 {
            let failure = errno
            try? FileManager.default.removeItem(at: destination)
            throw posixError(failure)
        }
    }

    private static func posixError(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    /// Moves `partial` to `final` unless `final` exists. On any failure the partial is removed.
    /// `exclusiveRename` is a test seam standing in for `renamex_np(..., RENAME_EXCL)`; it returns 0 or an errno.
    static func commit(
        partial: URL, to final: URL,
        exclusiveRename: (String, String) -> Int32 = { src, dst in
            renamex_np(src, dst, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
        }
    ) throws {
        let code = exclusiveRename(partial.path, final.path)
        if code == 0 { return }
        if code == ENOTSUP || code == EINVAL {
            try commitWithoutExclusiveRename(partial: partial, to: final)
            return
        }
        try? FileManager.default.removeItem(at: partial)
        if code == EEXIST { throw DownscaleError.outputExists }
        throw DownscaleError.encoderFailed("could not move the finished file into place (errno \(code))")
    }

    /// For volumes without `RENAME_EXCL`: claim the final name with an exclusive create, then rename over that
    /// placeholder, which is ours.
    private static func commitWithoutExclusiveRename(partial: URL, to final: URL) throws {
        let fd = open(final.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        guard fd >= 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: partial)
            if code == EEXIST { throw DownscaleError.outputExists }
            throw DownscaleError.encoderFailed("could not claim the output name (errno \(code))")
        }
        close(fd)
        if rename(partial.path, final.path) != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: final)
            try? FileManager.default.removeItem(at: partial)
            throw DownscaleError.encoderFailed("could not move the finished file into place (errno \(code))")
        }
    }
}
