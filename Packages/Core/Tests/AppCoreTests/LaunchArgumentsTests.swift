import Testing

@testable import AppCore

@Suite struct LaunchArgumentsTests {
    @Test func readsTheValueAfterTheFlag() {
        #expect(LaunchArguments.value(of: "-uiTesting", in: ["app", "-uiTesting", "/tmp/x", "-other"]) == "/tmp/x")
    }

    @Test func aMissingFlagOrMissingValueIsNil() {
        #expect(LaunchArguments.value(of: "-uiTesting", in: ["app"]) == nil)
        #expect(LaunchArguments.value(of: "-uiTesting", in: ["app", "-uiTesting"]) == nil)
        #expect(LaunchArguments.value(of: "-uiTesting", in: []) == nil)
    }
}
