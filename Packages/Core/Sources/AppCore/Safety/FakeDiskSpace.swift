import Foundation
import Synchronization

/// A disk with chosen numbers, for tests. A URL belongs to the volume whose root is the longest prefix of its path.
/// A URL under no registered volume belongs to `fallback` (default: a roomy volume called "Fake"), or to none when
/// `fallback` is nil.
public final class FakeDiskSpace: DiskSpaceProviding {
    private struct Entry {
        let root: String
        var volume: VolumeSpace
    }

    private let state: Mutex<(entries: [Entry], fallback: VolumeSpace?)>

    public init(fallback: VolumeSpace? = VolumeSpace(id: "fake", name: "Fake", availableBytes: Int64.max / 2)) {
        state = Mutex(([], fallback))
    }

    /// Everything the checks ask about is on one volume with this much room.
    public convenience init(available: Int64, name: String = "Fake") {
        self.init(fallback: VolumeSpace(id: "fake", name: name, availableBytes: available))
    }

    /// Registers a volume mounted at `root`.
    public func setVolume(at root: URL, name: String, available: Int64) {
        let path = root.standardizedFileURL.path
        state.withLock {
            $0.entries.removeAll { $0.root == path }
            $0.entries.append(Entry(root: path, volume: VolumeSpace(id: path, name: name, availableBytes: available)))
        }
    }

    public func volume(containing url: URL) -> VolumeSpace? {
        let path = url.standardizedFileURL.path
        return state.withLock { state in
            let match = state.entries
                .filter { path == $0.root || path.hasPrefix($0.root + "/") }
                .max { $0.root.count < $1.root.count }
            return match?.volume ?? state.fallback
        }
    }
}
