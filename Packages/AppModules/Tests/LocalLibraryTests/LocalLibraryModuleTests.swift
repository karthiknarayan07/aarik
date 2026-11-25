import Testing

@testable import LocalLibrary

@Test func moduleIsLinked() {
    #expect(LocalLibraryModule.name == "LocalLibrary")
}
