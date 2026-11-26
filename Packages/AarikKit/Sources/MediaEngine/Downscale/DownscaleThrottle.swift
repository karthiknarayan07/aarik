import Dispatch
import Synchronization

/// How hard downscales work right now, set by the app from the speed setting and the Mac's heat (`PressureState`).
/// The limit applies to new work as running downscales finish; the priority applies to downscales that start later.
public enum DownscaleThrottle {
    private static let background = Mutex(false)

    /// At most `limit` downscales at once; `background` runs the encoder's blocking work at background priority.
    public static func apply(limit: Int, background: Bool) async {
        self.background.withLock { $0 = background }
        await WorkSlots.downscales.setLimit(limit)
    }

    /// The priority for the blocking work of a downscale that starts now.
    static var qos: DispatchQoS { qos(background: background.withLock { $0 }) }

    static func qos(background: Bool) -> DispatchQoS { background ? .background : .unspecified }
}
