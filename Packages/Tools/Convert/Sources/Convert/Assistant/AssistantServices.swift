import Assistant
import Foundation

/// The assistant's pieces for the app to hold: availability, and the plain-words search for each library grid.
@MainActor
public final class AssistantServices {
    public let availability: AssistantAvailability
    public let localSearch: AssistantSearch
    public let photosSearch: AssistantSearch
    /// "Why?" explanations of results, remembered per job.
    public let explanations: OutcomeExplanations
    /// The Overview's groups of videos and the model's picks among them.
    public let smartPicks: SmartPicksStore

    public init(client: any LanguageModelClient = .real, observesActivation: Bool = true) {
        let availability = AssistantAvailability(client: client, observesActivation: observesActivation)
        self.availability = availability
        let translator = QueryTranslator(client: client)
        self.localSearch = AssistantSearch(availability: availability, translator: translator)
        self.photosSearch = AssistantSearch(availability: availability, translator: translator)
        self.explanations = OutcomeExplanations(explainer: OutcomeExplainer(client: client))
        self.smartPicks = SmartPicksStore(availability: availability, picker: SmartPicker(client: client))
    }

    public var isAvailable: Bool { availability.isAvailable }
}
