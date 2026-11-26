import Foundation
import Testing

@testable import DownscaleVideo

/// Records which bodies ran inside the gate and how many were inside at once.
private actor Occupancy {
    private(set) var current = 0
    private(set) var peak = 0
    private(set) var entered: [String] = []

    func enter(_ name: String) {
        current += 1
        peak = max(peak, current)
        entered.append(name)
    }

    func leave() { current -= 1 }
}

private func waitForWaiters(_ gate: DownloadGate, _ count: Int) async {
    while await gate.waitingCount != count { await Task.yield() }
}

@Test(.timeLimit(.minutes(1))) func oneDownloadAtATimeAndAWaitingOneCanBeCancelled() async throws {
    let gate = DownloadGate()
    let occupancy = Occupancy()
    let (hold, release) = AsyncStream.makeStream(of: Void.self)
    let (inside, insideSink) = AsyncStream.makeStream(of: String.self)
    var insideIterator = inside.makeAsyncIterator()

    let first = Task {
        try await gate.run {
            await occupancy.enter("first")
            insideSink.yield("first")
            for await _ in hold { break }
            await occupancy.leave()
        }
    }
    #expect(await insideIterator.next() == "first")
    #expect(await gate.isBusy)

    // A second and a third wait their turn; the second is cancelled and never runs.
    let second = Task {
        try await gate.run {
            await occupancy.enter("second")
            await occupancy.leave()
        }
    }
    await waitForWaiters(gate, 1)
    let third = Task {
        try await gate.run {
            await occupancy.enter("third")
            insideSink.yield("third")
            await occupancy.leave()
        }
    }
    await waitForWaiters(gate, 2)
    second.cancel()
    await #expect(throws: CancellationError.self) { try await second.value }
    #expect(await gate.waitingCount == 1)
    #expect(await occupancy.current == 1)

    release.yield()
    try await first.value
    #expect(await insideIterator.next() == "third")
    try await third.value

    #expect(await occupancy.entered == ["first", "third"])
    #expect(await occupancy.peak == 1)
    #expect(await gate.isBusy == false)
}

@Test func aCancelledCallerNeverEntersAFreeGate() async throws {
    let gate = DownloadGate()
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await gate.run { 1 }
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await gate.isBusy == false)
}

@Test func theGateIsFreeAgainAfterABodyThrows() async throws {
    struct Failure: Error {}
    let gate = DownloadGate()
    await #expect(throws: Failure.self) { try await gate.run { throw Failure() } }
    #expect(try await gate.run { 7 } == 7)
}
