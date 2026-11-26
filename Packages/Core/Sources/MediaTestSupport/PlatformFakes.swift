import AppCore
import Foundation

// Fakes for the platform seams in `AppCore/Platform` and `AppCore/Pressure`, so tests never touch the Trash, Finder,
// the pasteboard, IOKit or `UIDevice`.

@MainActor
public final class FakeThermalSource: ThermalSource {
    public var level: ThermalLevel
    private var handler: (@MainActor () -> Void)?

    public init(level: ThermalLevel = .nominal) { self.level = level }

    public func observe(_ handler: @escaping @MainActor () -> Void) { self.handler = handler }

    /// Changes the reading and notifies the observer.
    public func set(_ level: ThermalLevel) {
        self.level = level
        handler?()
    }
}

@MainActor
public final class FakePowerSource: PowerSource {
    public var snapshot: PowerSnapshot
    private var handler: (@MainActor () -> Void)?

    public init(snapshot: PowerSnapshot = .pluggedIn) { self.snapshot = snapshot }

    public func observe(_ handler: @escaping @MainActor () -> Void) { self.handler = handler }

    public func set(_ snapshot: PowerSnapshot) {
        self.snapshot = snapshot
        handler?()
    }
}

@MainActor
public final class FakeActivityStarter: ActivityStarter {
    public private(set) var begun = 0
    public private(set) var ended = 0
    public private(set) var reasons: [String] = []
    public var isHeld: Bool { begun > ended }

    public init() {}

    public func begin(reason: String) -> any ActivityToken {
        begun += 1
        reasons.append(reason)
        return Token(self)
    }

    private final class Token: ActivityToken {
        let owner: FakeActivityStarter
        init(_ owner: FakeActivityStarter) { self.owner = owner }
        func end() { owner.ended += 1 }
    }
}

/// Records what would be trashed; can be told to fail.
public final class FakeFileTrasher: FileTrasher, @unchecked Sendable {
    private let lock = NSLock()
    private var trashedURLs: [URL] = []
    public var failure: (any Error)?

    public init(failure: (any Error)? = nil) { self.failure = failure }

    public var trashed: [URL] { lock.withLock { trashedURLs } }

    public func moveToTrash(_ url: URL) throws -> URL {
        if let failure { throw failure }
        lock.withLock { trashedURLs.append(url) }
        return URL(filePath: "/FakeTrash/" + url.lastPathComponent)
    }
}

@MainActor
public final class FakeFileRevealer: FileRevealer {
    public private(set) var revealed: [[URL]] = []
    public private(set) var opened: [URL] = []

    public init() {}

    public func reveal(_ urls: [URL]) { revealed.append(urls) }
    public func open(_ url: URL) { opened.append(url) }
}

@MainActor
public final class FakePasteboard: Pasteboarding {
    public private(set) var text: String?
    public private(set) var fileURLs: [URL] = []

    public init() {}

    public func copy(text: String) {
        self.text = text
        fileURLs = []
    }

    public func copy(fileURLs: [URL]) {
        self.fileURLs = fileURLs
        text = nil
    }
}

/// A background grant the test can expire.
@MainActor
public final class FakeBackgroundGrant: BackgroundExecutionGrant {
    public private(set) var acquired: [(reason: String, title: String, subtitle: String)] = []
    public private(set) var endedCount = 0
    private var expirations: [@MainActor () -> Void] = []

    public init() {}

    public var isHeld: Bool { acquired.count > endedCount }

    public func acquire(
        reason: String, title: String, subtitle: String, onExpiration: @escaping @MainActor () -> Void
    ) -> any ActivityToken {
        acquired.append((reason, title, subtitle))
        expirations.append(onExpiration)
        return Token(self)
    }

    /// The system takes the grant back.
    public func expire() {
        for handler in expirations { handler() }
    }

    private final class Token: ActivityToken {
        let owner: FakeBackgroundGrant
        init(_ owner: FakeBackgroundGrant) { self.owner = owner }
        func end() { owner.endedCount += 1 }
    }
}
