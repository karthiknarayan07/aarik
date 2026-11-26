import Darwin
import Foundation

/// Which file sits at a path, and its size and modification time: enough to tell that the original a Replace is
/// about to trash is still the very file the conversion read.
struct FileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    let size: Int64
    let modified: timespec

    init(of url: URL) throws {
        var info = stat()
        guard stat(url.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        device = info.st_dev
        inode = info.st_ino
        size = Int64(info.st_size)
        modified = info.st_mtimespec
    }

    /// True when `url` is still this file, unchanged.
    func matches(_ url: URL) -> Bool {
        (try? FileIdentity(of: url)) == self
    }

    static func == (lhs: FileIdentity, rhs: FileIdentity) -> Bool {
        lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.size == rhs.size
            && lhs.modified.tv_sec == rhs.modified.tv_sec && lhs.modified.tv_nsec == rhs.modified.tv_nsec
    }
}
