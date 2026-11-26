import Foundation
import FoundationModels

/// Why the model can't be asked right now.
public enum AssistantUnavailableReason: Sendable, Equatable {
    case deviceNotEligible
    case notEnabled
    case modelNotReady
    case unsupportedLanguage
    case unknown
}

/// One earlier message, as the model is reminded of it.
public struct ChatTurn: Sendable, Equatable {
    public enum Role: Sendable, Equatable { case user, assistant }
    public let role: Role
    public let text: String
    public init(_ role: Role, _ text: String) {
        self.role = role
        self.text = text
    }
}

/// Everything one chat turn needs. `invoke` runs a tool the model called and returns the text to tell the model.
public struct ChatRequest: Sendable {
    public let prompt: String
    public let instructions: String
    public let history: [ChatTurn]
    public let tools: [any AssistantTool]
    public let invoke: @Sendable (_ tool: String, _ arguments: AssistantArguments) async -> String

    public init(
        prompt: String, instructions: String, history: [ChatTurn] = [], tools: [any AssistantTool] = [],
        invoke: @escaping @Sendable (String, AssistantArguments) async -> String
    ) {
        self.prompt = prompt
        self.instructions = instructions
        self.history = history
        self.tools = tools
        self.invoke = invoke
    }

    /// The rules, then a short reminder of the chat so far (the model starts each turn fresh).
    public var fullInstructions: String {
        guard !history.isEmpty else { return instructions }
        let recap = history.suffix(8).map { turn in
            "\(turn.role == .user ? "Person" : "Assistant"): \(String(turn.text.prefix(400)))"
        }.joined(separator: "\n")
        return instructions + "\n\nThe chat so far:\n" + recap
    }
}

/// Offers an `AssistantTool` to the system model. Its arguments arrive as generated content and are passed on as text.
struct FoundationModelsToolAdapter: FoundationModels.Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let tool: any AssistantTool
    let invoke: @Sendable (String, AssistantArguments) async -> String
    let parameters: GenerationSchema

    init(tool: any AssistantTool, invoke: @escaping @Sendable (String, AssistantArguments) async -> String) {
        self.tool = tool
        self.invoke = invoke
        let properties = tool.parameters.map { parameter -> DynamicGenerationSchema.Property in
            let schema: DynamicGenerationSchema
            switch parameter.kind {
            case .string:
                schema =
                    parameter.allowed.isEmpty
                    ? DynamicGenerationSchema(type: String.self)
                    : DynamicGenerationSchema(name: parameter.name, anyOf: parameter.allowed)
            case .integer: schema = DynamicGenerationSchema(type: Int.self)
            case .boolean: schema = DynamicGenerationSchema(type: Bool.self)
            }
            return .init(name: parameter.name, description: parameter.summary, schema: schema, isOptional: true)
        }
        let root = DynamicGenerationSchema(
            name: "\(tool.name)_arguments", description: tool.summary, properties: properties)
        let empty = DynamicGenerationSchema(name: "\(tool.name)_arguments", properties: [])
        // A schema that can't be built leaves the tool without inputs rather than failing the whole chat.
        self.parameters =
            (try? GenerationSchema(root: root, dependencies: []))
            ?? (try! GenerationSchema(root: empty, dependencies: []))
    }

    var name: String { tool.name }
    var description: String { tool.summary }

    func call(arguments: GeneratedContent) async throws -> String {
        var values: [String: String] = [:]
        for parameter in tool.parameters {
            switch parameter.kind {
            case .string:
                if let value = try? arguments.value(String?.self, forProperty: parameter.name) {
                    values[parameter.name] = value
                }
            case .integer:
                if let value = try? arguments.value(Int?.self, forProperty: parameter.name) {
                    values[parameter.name] = String(value)
                }
            case .boolean:
                if let value = try? arguments.value(Bool?.self, forProperty: parameter.name) {
                    values[parameter.name] = String(value)
                }
            }
        }
        return await invoke(tool.name, AssistantArguments(values))
    }
}
