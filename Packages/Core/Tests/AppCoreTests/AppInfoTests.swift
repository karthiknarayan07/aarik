import Foundation
import Testing

@testable import AppCore

@Suite struct AppInfoTests {
    private final class BundleToken {}

    @Test func theDisplayNameIsNeverEmpty() {
        #expect(!AppInfo.displayName.isEmpty)
        // A bundle without a name (a test runner, a command line tool) reads as something, never as nothing.
        #expect(!AppInfo.displayName(in: Bundle(for: BundleToken.self)).isEmpty)
    }
}
