import Foundation
import FoundationModels

/// Why a model request produced nothing. The app never shows these: every feature falls back to what it did
/// before the assistant existed.
public enum AssistantError: Error, Sendable, Equatable {
    case unavailable
    case emptyInput
    case timedOut
    /// The caller gave up (for example the user typed again). Not a failure of the model.
    case cancelled
    case guardrail
    case contextTooLong
    case rateLimited
    case unsupportedLanguage
    case failed
}

/// The one way the assistant talks to a language model, so tests use a fake and never need the model.
///
/// Prompts carry metadata only (names, dates, sizes, resolutions, codecs, badges, outcome reasons); instructions
/// carry the rules. Nothing here logs a prompt or a response.
public protocol LanguageModelClient: Sendable {
    /// Whether the model can be asked right now: Apple Intelligence is on, the model is ready and the system
    /// language is supported.
    var isAvailable: Bool { get }

    func respond(to prompt: String, instructions: String) async throws -> String

    func generate<T: Generable & Sendable>(_ prompt: String, instructions: String) async throws -> T

    /// Why `isAvailable` is false; nil while it is true.
    var unavailableReason: AssistantUnavailableReason? { get }

    /// A chat turn: streams the reply as the text so far (each element holds everything written up to then) and
    /// calls the request's `invoke` whenever the model wants a tool. The default answers in one piece, without tools.
    func streamChat(_ request: ChatRequest) -> AsyncThrowingStream<String, any Error>
}

extension LanguageModelClient {
    public var unavailableReason: AssistantUnavailableReason? { isAvailable ? nil : .unknown }

    public func streamChat(_ request: ChatRequest) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(try await respond(to: request.prompt, instructions: request.fullInstructions))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// The system's on-device model.
public struct SystemLanguageModelClient: LanguageModelClient {
    public init() {}

    public var isAvailable: Bool {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { return false }
        return model.supportsLocale()
    }

    public var unavailableReason: AssistantUnavailableReason? {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available: return model.supportsLocale() ? nil : .unsupportedLanguage
        case .unavailable(.deviceNotEligible): return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): return .notEnabled
        case .unavailable(.modelNotReady): return .modelNotReady
        default: return .unknown
        }
    }

    public func streamChat(_ request: ChatRequest) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard isAvailable else { throw AssistantError.unavailable }
                    let tools: [any FoundationModels.Tool] = request.tools.map {
                        FoundationModelsToolAdapter(tool: $0, invoke: request.invoke)
                    }
                    let session = LanguageModelSession(tools: tools, instructions: request.fullInstructions)
                    for try await snapshot in session.streamResponse(to: request.prompt) {
                        continuation.yield(snapshot.content)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: Self.map(error)) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func respond(to prompt: String, instructions: String) async throws -> String {
        guard isAvailable else { throw AssistantError.unavailable }
        do {
            let session = LanguageModelSession(instructions: instructions)
            return try await session.respond(to: prompt).content
        } catch {
            throw Self.map(error)
        }
    }

    public func generate<T: Generable & Sendable>(_ prompt: String, instructions: String) async throws -> T {
        guard isAvailable else { throw AssistantError.unavailable }
        do {
            let session = LanguageModelSession(instructions: instructions)
            return try await session.respond(to: prompt, generating: T.self).content
        } catch {
            throw Self.map(error)
        }
    }

    /// Cancellation passes through; every model error becomes an `AssistantError`.
    static func map(_ error: any Error) -> any Error {
        if error is CancellationError || error is AssistantError { return error }
        if #available(macOS 27, iOS 27, *), let mapped = mapCurrent(error) { return mapped }
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .refusal: return AssistantError.guardrail
            case .exceededContextWindowSize: return AssistantError.contextTooLong
            case .rateLimited: return AssistantError.rateLimited
            case .unsupportedLanguageOrLocale: return AssistantError.unsupportedLanguage
            default: return AssistantError.failed
            }
        }
        return AssistantError.failed
    }

    @available(macOS 27, iOS 27, *)
    private static func mapCurrent(_ error: any Error) -> AssistantError? {
        guard let error = error as? LanguageModelError else { return nil }
        switch error {
        case .guardrailViolation, .refusal: return .guardrail
        case .contextSizeExceeded: return .contextTooLong
        case .rateLimited: return .rateLimited
        case .unsupportedLanguageOrLocale: return .unsupportedLanguage
        case .timeout: return .timedOut
        default: return .failed
        }
    }
}

extension LanguageModelClient where Self == SystemLanguageModelClient {
    /// The system's on-device model.
    public static var real: SystemLanguageModelClient { SystemLanguageModelClient() }
}
