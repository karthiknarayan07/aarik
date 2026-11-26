import Testing

@testable import Convert
@testable import Assistant

@MainActor
@Suite struct AssistantServicesTests {
    @Test func everyControlIsHiddenWhenTheModelIsUnavailable() {
        let client = FakeLanguageModelClient(isAvailable: false)
        let services = AssistantServices(client: client, observesActivation: false)
        #expect(!services.isAvailable)
        #expect(!services.localSearch.isVisible)
        #expect(!services.photosSearch.isVisible)
    }

    @Test func controlsAppearOnceTheModelBecomesAvailable() {
        let client = FakeLanguageModelClient(isAvailable: false)
        let services = AssistantServices(client: client, observesActivation: false)
        client.isAvailable = true
        services.availability.refresh()
        #expect(services.isAvailable)
        #expect(services.localSearch.isVisible)
    }
}
