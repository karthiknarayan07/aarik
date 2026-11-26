/// The first Replace of a session asks for confirmation. A confirmation counts only once videos were actually
/// added with it: confirming and then cancelling a later step (such as the metadata-loss sheet) asks again next
/// time.
public struct ReplaceConsent: Sendable, Equatable {
    private var isGiven = false
    private var isPending = false

    public init() {}

    /// Ask before adding Replace jobs.
    public var needsAsking: Bool { !isGiven }

    /// The user confirmed Replace; it counts once the videos are added.
    public mutating func confirm() {
        isPending = true
    }

    /// The videos were added: a pending confirmation now holds for the rest of the session.
    public mutating func videosAdded() {
        if isPending { isGiven = true }
        isPending = false
    }

    /// Nothing was added after all.
    public mutating func abandon() {
        isPending = false
    }
}
