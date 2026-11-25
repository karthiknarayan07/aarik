import Foundation
import Testing

@testable import MediaEngine

@Suite struct DownscaleErrorTests {
    @Test func everyCaseReadsAsAPlainSentence() {
        let cases: [DownscaleError] = [
            .outputExists, .sourceAlreadySmall, .unsupportedSource("spatial video"), .encoderFailed("errno 13"),
        ]
        for error in cases {
            let text = error.localizedDescription
            #expect(!text.contains("DownscaleError"))
            #expect(!text.contains("errno"))
            #expect(text.hasSuffix("."))
        }
        #expect(DownscaleError.sourceAlreadySmall.localizedDescription == "The video is already small.")
    }
}
