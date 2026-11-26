import AVFoundation
import AppCore
import Foundation
import MediaTestSupport
import Synchronization
import Testing

@testable import MediaEngine

/// A downscale waits for decoded frames with blocking reads. Those must never run on Swift's shared cooperative
/// pool: enough downscales at once (10 on an 8-core Mac) blocked every pool thread while the work they waited for
/// needed one, and none finished.
@Suite struct ConcurrentDownscaleTests {
    @Test(.timeLimit(.minutes(5))) func downscaleWorkRunsOnItsOwnQueueNotTheSharedPool() async throws {
        var options = ClipOptions()
        options.width = 1280
        options.height = 720
        options.fps = 10
        options.hdr = .sdr
        let clip = try await FixtureFactory.makeClip(options)
        let directory = clip.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let label = Mutex<String?>(nil)
        var downscaler = VideoDownscaler()
        // Runs inside the encode loop, where the blocking reads happen.
        downscaler.beforeStartWriting = { _ in
            label.withLock { $0 = String(cString: __dispatch_queue_get_label(nil)) }
        }

        try await downscaler.downscale(
            source: clip, output: directory.appending(path: "out.mov"),
            spec: DownscaleSpec(targetShortSide: 360, averageBitRate: 500_000)
        ) { _ in }

        #expect(label.withLock { $0 } == "downscale out.mov")
    }
}

/// Only a few downscales run at once, process-wide; the others wait their turn without holding a thread, so many
/// at once don't swamp the hardware encoder.
@Suite struct WorkSlotsTests {
    @Test(.timeLimit(.minutes(1))) func aThirdDownscaleWaitsForAFreeSlot() async {
        let slots = WorkSlots(count: 2)
        await slots.acquire()
        await slots.acquire()
        let (acquired, continuation) = AsyncStream.makeStream(of: Void.self)
        let third = Task {
            await slots.acquire()
            continuation.yield()
        }
        // It waits: both slots are taken.
        while await slots.waiting == 0 { await Task.yield() }
        #expect(await slots.free == 0)

        await slots.release()
        var iterator = acquired.makeAsyncIterator()
        await iterator.next()
        await third.value
        // The released slot went straight to the waiting one.
        #expect(await slots.waiting == 0)
        #expect(await slots.free == 0)
    }

    @Test func sharedSlotsLeaveRoomForOtherWork() {
        #expect(WorkSlots.defaultCount >= 2)
        #expect(WorkSlots.defaultCount < max(ProcessInfo.processInfo.activeProcessorCount, 3))
    }

    // MARK: Adjustable limit

    @Test(.timeLimit(.minutes(1))) func raisingTheLimitAdmitsWaitersAtOnce() async {
        let slots = WorkSlots(count: 1)
        await slots.acquire()
        let (acquired, continuation) = AsyncStream.makeStream(of: Void.self)
        let second = Task {
            await slots.acquire()
            continuation.yield()
        }
        while await slots.waiting == 0 { await Task.yield() }

        await slots.setLimit(2)
        var iterator = acquired.makeAsyncIterator()
        await iterator.next()
        await second.value
        #expect(await slots.waiting == 0)
        #expect(await slots.free == 0)
    }

    @Test(.timeLimit(.minutes(1))) func loweringTheLimitNeverStopsRunningWorkAndAppliesAsItFinishes() async {
        let slots = WorkSlots(count: 3)
        await slots.acquire()
        await slots.acquire()
        await slots.acquire()
        await slots.setLimit(1)
        // All three keep their slots; a new caller waits.
        #expect(await slots.free == 0)
        let (acquired, continuation) = AsyncStream.makeStream(of: Void.self)
        let next = Task {
            await slots.acquire()
            continuation.yield()
        }
        while await slots.waiting == 0 { await Task.yield() }

        // Two finish: still at the new limit, so the waiter keeps waiting.
        await slots.release()
        await slots.release()
        #expect(await slots.waiting == 1)
        // The last one finishes: now there is room for one.
        await slots.release()
        var iterator = acquired.makeAsyncIterator()
        await iterator.next()
        await next.value
        #expect(await slots.waiting == 0)
        #expect(await slots.free == 0)
        await slots.release()
        #expect(await slots.free == 1)
    }

    @Test func theLimitIsAtLeastOne() async {
        let slots = WorkSlots(count: 0)
        #expect(await slots.free == 1)
        await slots.setLimit(-3)
        #expect(await slots.free == 1)
    }

    @Test func quietRunsTheBlockingWorkInTheBackground() {
        #expect(DownscaleThrottle.qos(background: true) == .background)
        #expect(DownscaleThrottle.qos(background: false) == .unspecified)
    }
}
