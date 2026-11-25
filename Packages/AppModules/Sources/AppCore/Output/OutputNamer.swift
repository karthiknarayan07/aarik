import Darwin
import Foundation

public enum OutputNamer {
    /// `<stem> (<label>).<ext>`, then `<stem> (<label>) 2.<ext>`, `... 3.<ext>` and so on:
    /// the first name that does not exist in `directory`. A dangling symlink counts as taken.
    public static func url(for source: URL, label: String, in directory: URL) -> URL {
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        func candidate(_ n: Int) -> URL {
            let suffix = n == 1 ? "" : " \(n)"
            let name = "\(stem) (\(label))\(suffix)"
            return directory.appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)")
        }
        var n = 1
        while exists(candidate(n)) { n += 1 }
        return candidate(n)
    }

    /// `lstat` semantics: does not follow symlinks.
    private static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }
}
