import AppCore
import Darwin
import Foundation

/// Finder tags, extended attributes and dates: read as `fs.*` items, and copied between files.
enum FileAttributes {
    /// System-managed or SIP-protected attributes, never read or copied.
    static let excludedAttributes: Set<String> = [
        "com.apple.quarantine", "com.apple.provenance", "com.apple.lastuseddate#PS",
        "com.apple.macl", "com.apple.rootless",
    ]

    /// `setxattr` failures that skip one attribute instead of failing the copy.
    private static let skippableErrors: Set<Int32> = [EPERM, EACCES, ENOTSUP]

    static func read(_ url: URL) throws -> [MetadataItem] {
        var items: [MetadataItem] = []
        #if os(macOS)
            let values = try uncached(url).resourceValues(forKeys: [.tagNamesKey, .creationDateKey])
            if let tags = values.tagNames, !tags.isEmpty {
                items.append(
                    MetadataItem(
                        key: "fs.tags", category: .fileSystem, displayName: "Finder tags",
                        value: tags.sorted().joined(separator: ",")))
            }
        #else
            let values = try uncached(url).resourceValues(forKeys: [.creationDateKey])
        #endif
        for name in try attributeNames(url) {
            items.append(
                MetadataItem(
                    key: "fs.xattr.\(name)", category: .fileSystem, displayName: "Extended attribute \(name)",
                    value: sha256Hex(try attribute(name, of: url))))
        }
        if let created = values.creationDate {
            items.append(
                MetadataItem(
                    key: "fs.creationDate", category: .fileSystem, displayName: "File creation date",
                    value: created.ISO8601Format()))
        }
        return items
    }

    /// Copies tags, every non-excluded extended attribute, and the creation and modification dates.
    /// Best-effort per attribute: one the destination refuses (EPERM, EACCES, ENOTSUP) is skipped, so it shows up
    /// as lost when source and output inventories are diffed. Other errors, and tag or date failures, throw.
    static func copy(from source: URL, to destination: URL) throws {
        for name in try attributeNames(source) {
            let data = try attribute(name, of: source)
            let result = data.withUnsafeBytes {
                setxattr(destination.path, name, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW)
            }
            if result != 0 {
                let code = errno
                if skippableErrors.contains(code) { continue }
                throw posixError(code)
            }
        }

        // Tags normally travel in their xattr above; set them only if that did not carry them.
        #if os(macOS)
            let sourceValues = try uncached(source).resourceValues(forKeys: [
                .tagNamesKey, .creationDateKey, .contentModificationDateKey,
            ])
            let sourceTags = sourceValues.tagNames ?? []
            var destinationURL = uncached(destination)
            if try destinationURL.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? [] != sourceTags {
                var tagValues = URLResourceValues()
                tagValues.tagNames = sourceTags
                try destinationURL.setResourceValues(tagValues)
            }
        #else
            // Finder tags are a Mac concept.
            let sourceValues = try uncached(source).resourceValues(forKeys: [
                .creationDateKey, .contentModificationDateKey,
            ])
        #endif

        var dates: [FileAttributeKey: Any] = [:]
        dates[.creationDate] = sourceValues.creationDate
        dates[.modificationDate] = sourceValues.contentModificationDate
        if !dates.isEmpty {
            try FileManager.default.setAttributes(dates, ofItemAtPath: destination.path)
        }
    }

    /// Sorted names of the file's extended attributes, minus the excluded ones.
    private static func attributeNames(_ url: URL) throws -> [String] {
        let size = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
        if size < 0 { throw posixError() }
        if size == 0 { return [] }
        var buffer = [CChar](repeating: 0, count: size)
        let read = listxattr(url.path, &buffer, size, XATTR_NOFOLLOW)
        if read < 0 { throw posixError() }
        let names = buffer.prefix(read).split(separator: 0).map {
            String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        return names.filter { !excludedAttributes.contains($0) }.sorted()
    }

    private static func attribute(_ name: String, of url: URL) throws -> Data {
        let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        if size < 0 { throw posixError() }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        if read < 0 { throw posixError() }
        return data.prefix(read)
    }

    /// A fresh URL for the same path, so neither stale cached resource values are read nor the caller's URL
    /// instance is left caching values that this code is about to change.
    private static func uncached(_ url: URL) -> URL {
        var fresh = URL(filePath: url.path(percentEncoded: false))
        fresh.removeAllCachedResourceValues()
        return fresh
    }

    private static func posixError(_ code: Int32 = errno) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
