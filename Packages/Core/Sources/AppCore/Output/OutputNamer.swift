import Darwin
import Foundation

public enum OutputNamer {
    /// `<stem> (<label>).<ext>`, then `<stem> (<label>) 2.<ext>`, `... 3.<ext>` and so on:
    /// the first name that does not exist in `directory`. A dangling symlink counts as taken. `ext` is the
    /// source's own extension unless `pathExtension` is given (an output in another container).
    public static func url(for source: URL, label: String, in directory: URL, pathExtension: String? = nil) -> URL {
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = pathExtension ?? source.pathExtension
        func candidate(_ n: Int) -> URL {
            let suffix = n == 1 ? "" : " \(n)"
            let name = "\(stem) (\(label))\(suffix)"
            return directory.appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)")
        }
        var n = 1
        while exists(candidate(n)) { n += 1 }
        return candidate(n)
    }

    /// `<name>.<ext>` (the source's own name), then `<name> 2.<ext>`, `<name> 3.<ext>` and so on: the first name
    /// that does not exist in `directory`. For copies that keep the original's name, such as a backup.
    public static func url(keepingNameOf source: URL, in directory: URL) -> URL {
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        func candidate(_ n: Int) -> URL {
            let name = n == 1 ? stem : "\(stem) \(n)"
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
