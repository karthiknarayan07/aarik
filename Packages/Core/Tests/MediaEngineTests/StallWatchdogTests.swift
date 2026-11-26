import AVFoundation
import Foundation
import MediaTestSupport
import Synchronization
import Testing

@testable import MediaEngine

/// Blocks the calling thread, as an uninterruptible framework call does.
private func blockThread(seconds: Double) {
    Thread.sleep(forTimeInterval: seconds)
}

/// A stalled writer or encoder fails the job as "The encoder stopped responding" instead of hanging, frees its
/// `WorkSlots` slot and leaves no partial file. The limits are tiny and the stalls are forced through test seams, so
/// nothing here waits for a real 60 seconds.
@Suite struct StallWatchdogTests {
    private let spec = DownscaleSpec(targetShortSide: 360, averageBitRate: 2_000_000)

    /// In-loop limits are short; the outside watchdog's is long, so the loops are the ones that report.
    private let loopLimits = StallLimits(
        noProgress: .milliseconds(300), finish: .milliseconds(300), blockedCall: .seconds(30), poll: .milliseconds(50))

    private func makeClip(audio: Bool) async throws -> (clip: URL, directory: URL) {
        var options = ClipOptions()
        options.width = 1280
        options.height = 720
        options.hdr = .sdr
        options.seconds = 2
        options.includeAudio = audio
        let clip = try await FixtureFactory.makeClip(options)
        return (clip, clip.deletingLastPathComponent())
    }

    /// Runs a downscale with a stall forced at `point`; expects `stalled`, no partial or output, and the slot back.
    private func expectStall(
        at point: StallPoint, audio: Bool = false, limits: StallLimits, within seconds: Double = 20
    ) async throws {
        let (clip, directory) = try await makeClip(audio: audio)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appending(path: "output.mov")
        let slots = WorkSlots(count: 1)
        var downscaler = VideoDownscaler(stallLimits: limits)
        downscaler.forceStall = point
        downscaler.slots = slots

        let started = ContinuousClock.now
        await #expect(throws: DownscaleError.stalled) {
            try await downscaler.downscale(source: clip, output: output, spec: spec) { _ in }
        }
        let elapsed = ContinuousClock.now - started
        #expect(elapsed < .seconds(seconds), "took \(elapsed)")

        #expect(!FileManager.default.fileExists(atPath: output.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!names.contains { $0.contains(".partial-") }, "leaked: \(names)")
        #expect(names.contains(clip.lastPathComponent), "the source must still be there")
        #expect(await slots.free == 1, "the slot must be given back")

        // Retry works: the same output name, nothing forced.
        let retry = VideoDownscaler()
        try await retry.downscale(source: clip, output: output, spec: spec) { _ in }
        #expect(FileManager.default.fileExists(atPath: output.path))
    }

    // The four forced-stall tests each end in a full software re-encode (the retry): too slow on the Simulator, whose
    // encoder is not representative. The normal-run test below stays as the smoke encode.
    @Test(.timeLimit(.minutes(5)), .enabled(if: EncoderEnvironment.isRepresentative))
    func aVideoInputThatNeverTakesASampleFailsAsStalled() async throws {
        try await expectStall(at: .videoInput, limits: loopLimits)
    }

    @Test(.timeLimit(.minutes(5)), .enabled(if: EncoderEnvironment.isRepresentative))
    func aDrainThatNeverFinishesFailsAsStalled() async throws {
        try await expectStall(at: .drain, limits: loopLimits)
    }

    @Test(.timeLimit(.minutes(5)), .enabled(if: EncoderEnvironment.isRepresentative))
    func aFinishWritingThatNeverReturnsFailsAsStalled() async throws {
        try await expectStall(at: .finish, limits: loopLimits)
    }

    @Test(.timeLimit(.minutes(5)), .enabled(if: EncoderEnvironment.isRepresentative))
    func aBlockedReadIsAbandonedByTheWatchdogAndFreesTheSlot() async throws {
        // The loops can't report from inside a call that doesn't return: only the watchdog outside the job can.
        let limits = StallLimits(
            noProgress: .seconds(30), finish: .seconds(30), blockedCall: .milliseconds(500), poll: .milliseconds(50))
        try await expectStall(at: .blockingCall, limits: limits, within: 9)
    }

    @Test(.timeLimit(.minutes(5))) func aNormalRunIsNotMistakenForAStall() async throws {
        let (clip, directory) = try await makeClip(audio: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appending(path: "output.mov")
        let downscaler = VideoDownscaler(
            stallLimits: StallLimits(
                noProgress: .seconds(20), finish: .seconds(20), blockedCall: .seconds(20), poll: .milliseconds(50)))
        try await downscaler.downscale(source: clip, output: output, spec: spec) { _ in }
        #expect(FileManager.default.fileExists(atPath: output.path))
    }

    // MARK: - Pieces

    @Test func theHeartbeatReportsIdleTimeAndGivingUpAbortsAndRemovesThePartial() throws {
        let heartbeat = Heartbeat()
        let partial = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).partial")
        try Data([1, 2, 3]).write(to: partial)
        defer { try? FileManager.default.removeItem(at: partial) }
        // Mutex is noncopyable; the closure reaches it through a class.
        final class Flag: Sendable {
            let value = Mutex(false)
        }
        let flag = Flag()
        heartbeat.register(partial: partial) { flag.value.withLock { $0 = true } }

        #expect(!heartbeat.hasStalled)
        heartbeat.beat()
        #expect(heartbeat.idle < .seconds(5))
        heartbeat.giveUp()
        #expect(heartbeat.hasStalled)
        #expect(flag.value.withLock { $0 })
        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }

    @Test(.timeLimit(.minutes(1))) func theWatchdogFailsAHungRunWhileItsWorkNeverReturns() async throws {
        let heartbeat = Heartbeat()
        let limits = StallLimits(
            noProgress: .seconds(30), finish: .seconds(30), blockedCall: .milliseconds(200), poll: .milliseconds(20))
        await #expect(throws: DownscaleError.stalled) {
            // Work that ignores cancellation for a while, as a blocked framework call does.
            try await StallWatchdog.race(heartbeat: heartbeat, limits: limits) {
                blockThread(seconds: 2)
                return 1
            }
        }
    }

    @Test(.timeLimit(.minutes(1))) func aRunThatKeepsBeatingIsNotGivenUpOn() async throws {
        let heartbeat = Heartbeat()
        let limits = StallLimits(
            noProgress: .seconds(30), finish: .seconds(30), blockedCall: .milliseconds(300), poll: .milliseconds(20))
        let value = try await StallWatchdog.race(heartbeat: heartbeat, limits: limits) {
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(50))
                heartbeat.beat()
            }
            return 7
        }
        #expect(value == 7)
        #expect(!heartbeat.hasStalled)
    }
}
