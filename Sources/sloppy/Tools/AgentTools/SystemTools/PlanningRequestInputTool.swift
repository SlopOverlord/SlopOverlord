import AnyLanguageModel
import Foundation
import Protocols

struct PlanningRequestInputTool: CoreTool {
    let domain = "planning"
    let title = "Request plan input"
    let status = "fully_functional"
    let name = "planning.request_input"
    let description = "Pause a plan-mode turn and ask the user one to three structured questions."

    var parameters: GenerationSchema {
        let optionSchema = DynamicGenerationSchema(
            name: "PlanInputOption",
            properties: [
                .init(name: "id", description: "Stable option id", schema: DynamicGenerationSchema(type: String.self)),
                .init(name: "label", description: "Short option label", schema: DynamicGenerationSchema(type: String.self)),
                .init(name: "description", description: "Optional option detail", schema: DynamicGenerationSchema(type: String.self), isOptional: true)
            ]
        )
        let questionSchema = DynamicGenerationSchema(
            name: "PlanInputQuestion",
            properties: [
                .init(name: "id", description: "Stable question id", schema: DynamicGenerationSchema(type: String.self)),
                .init(name: "header", description: "Optional short header", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
                .init(name: "question", description: "Question text", schema: DynamicGenerationSchema(type: String.self)),
                .init(name: "options", description: "Two to four fixed options", schema: DynamicGenerationSchema(arrayOf: optionSchema)),
                .init(name: "allowCustomAnswer", description: "Whether a freeform custom answer is accepted; defaults to true", schema: DynamicGenerationSchema(type: Bool.self), isOptional: true)
            ]
        )
        return .objectSchema([
            .init(name: "title", description: "Optional short title for the input request", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(
                name: "questions",
                description: "Array of 1-3 question objects. Each question needs id, question, options, optional header, and optional allowCustomAnswer.",
                schema: DynamicGenerationSchema(arrayOf: questionSchema)
            )
        ])
    }

    func invoke(arguments: [String: JSONValue], context: ToolContext) async -> ToolInvocationResult {
        toolFailure(
            tool: name,
            code: "not_available",
            message: "`planning.request_input` is handled by the active runtime turn and is only available in plan mode.",
            retryable: false
        )
    }
}
