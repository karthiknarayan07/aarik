import Testing

@testable import AarikCore

@Suite("Signposts")
struct SignpostsTests {
    /// The interval names are documented in PERFORMANCE.md and used to compare traces; they must not drift.
    @Test func intervalNamesAreStable() {
        #expect(
            PipelineStage.allCases.map { "\($0.name)" }
                == ["read", "transfer", "encode", "write", "verify", "download", "save"])
        #expect(PipelineStage.allCases.allSatisfy { "\($0.name)" == $0.rawValue })
    }

    @Test func intervalsReturnTheirResultAndRethrow() async throws {
        #expect(Signposts.interval(.read) { 41 + 1 } == 42)
        #expect(
            await Signposts.interval(.download) {
                await Task.yield(); return 7
            } == 7)
        struct Boom: Error {}
        #expect(throws: Boom.self) { try Signposts.interval(.verify) { throw Boom() } }
        await #expect(throws: Boom.self) {
            try await Signposts.interval(.save) {
                await Task.yield(); throw Boom()
            }
        }
    }
}
