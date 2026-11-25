import CoreMedia
import Testing

@testable import MediaEngine

@Suite struct FrameRateLimiterTests {
    private func kept(_ times: [Double], maxFrameRate: Double?) -> [Bool] {
        var limiter = FrameRateLimiter(maxFrameRate: maxFrameRate)
        return times.map { limiter.shouldKeep(presentationTime: CMTime(seconds: $0, preferredTimescale: 600_000)) }
    }

    @Test func halves60To30() {
        let decisions = kept((0..<60).map { Double($0) / 60 }, maxFrameRate: 30)
        #expect(decisions.filter { $0 }.count == 30)
        #expect(decisions.first == true)
    }

    @Test func nilKeepsAll() {
        let decisions = kept((0..<60).map { Double($0) / 60 }, maxFrameRate: nil)
        #expect(decisions.allSatisfy { $0 })
    }

    @Test func handlesJitter() {
        let jitter: [Double] = [0.002, -0.002, 0.001, -0.001, 0]
        let times = (0..<60).map { Double($0) / 60 + ($0 == 0 ? 0 : jitter[$0 % jitter.count]) }
        let count = kept(times, maxFrameRate: 30).filter { $0 }.count
        #expect((29...31).contains(count))
    }
}
