import Foundation
import Testing

@testable import MediaEngine

@Suite struct DolbyVisionConfigTests {
    @Test func parsesProfile8_4() throws {
        let config = try #require(DolbyVisionConfig(record: Data([0x01, 0x00, 0x10, 0x35, 0x40])))
        #expect(config.profile == 8)
        #expect(config.level == 6)
        #expect(config.rpuPresent)
        #expect(!config.elPresent)
        #expect(config.blPresent)
        #expect(config.compatibilityID == 4)
        #expect(config.displayValue == "profile 8, level 6, compat 4")
    }

    @Test func rejectsShortRecord() {
        #expect(DolbyVisionConfig(record: Data([0x01, 0x00, 0x10, 0x35])) == nil)
    }
}
