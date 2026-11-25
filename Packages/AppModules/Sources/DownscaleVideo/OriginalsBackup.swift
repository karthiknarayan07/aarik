import AppCore
import Foundation
import MediaEngine

/// Where *Keep a copy of originals* puts each original before a Replace trashes it.
public struct OriginalsBackup: Sendable, Equatable {
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }
}

/// Why an original couldn't be backed up; the Replace doesn't happen.
enum OriginalsBackupError: Error, Equatable {
    case folderUnavailable
    case copyFailed
    case sizeMismatch

    /// Completes "The original was kept because …".
    var keptBecause: String {
        switch self {
        case .folderUnavailable: "the originals folder is missing or the drive isn't connected"
        case .copyFailed: "it couldn't be copied to the originals folder"
        case .sizeMismatch: "its copy in the originals folder didn't match"
        }
    }
}

extension DownscaleRunner {
    /// Copies `source` into `folder` under its own name (`<name> 2.<ext>` and so on when taken) and checks that the
    /// copy is `byteSize` bytes. The copy is written to a hidden partial file and appears under its final name only
    /// through an exclusive rename, so nothing is ever overwritten and a finished name always holds a whole copy.
    /// The folder is never created here: a missing folder (a disconnected drive) is an error.
    func backUp(_ source: URL, byteSize: Int64, into folder: URL) throws(OriginalsBackupError) -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { throw .folderUnavailable }
        // A crash or power loss mid-copy leaves `.<name>.partial-*` behind; clear this source's leftovers first.
        Self.removeStalePartials(of: folder.appending(path: source.lastPathComponent))
        let partial = folder.appending(path: ".\(source.lastPathComponent).partial-\(UUID().uuidString)")
        do {
            try FileManager.default.copyItem(at: source, to: partial)
        } catch {
            // A name we didn't create is never removed.
            if (error as NSError).code != NSFileWriteFileExistsError {
                try? FileManager.default.removeItem(at: partial)
            }
            throw .copyFailed
        }
        guard (try? sizeOf(partial)) == byteSize else {
            try? FileManager.default.removeItem(at: partial)
            throw .sizeMismatch
        }
        for _ in 0..<Self.maxNamingAttempts {
            let destination = OutputNamer.url(keepingNameOf: source, in: folder)
            do {
                try AtomicOutput.moveWithoutReplacing(partial, to: destination)
                return destination
            } catch let error as POSIXError where error.code == .EEXIST {
                continue
            } catch {
                break
            }
        }
        try? FileManager.default.removeItem(at: partial)
        throw .copyFailed
    }
}
