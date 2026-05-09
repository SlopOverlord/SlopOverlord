import AnyLanguageModel
import Foundation
import Protocols

struct PlanningProgressUpdateTool: CoreTool {
    let domain = "planning"
    let title = "Update build progress"
    let status = "fully_functional"
    let name = "planning.progress_update"
    let description = "Record a compact Build-mode progress checklist with Definition of Done items."

    var parameters: GenerationSchema {
        let itemSchema = DynamicGenerationSchema(
            name: "BuildProgressItem",
            properties: [
                .init(name: "id", description: "Stable item id", schema: DynamicGenerationSchema(type: String.self)),
                .init(name: "title", description: "Short work item title", schema: DynamicGenerationSchema(type: String.self)),
                .init(name: "status", description: "pending, in_progress, done, blocked, or skipped", schema: DynamicGenerationSchema(type: String.self)),
                .init(name: "definitionOfDone", description: "Observable completion criteria for this item", schema: DynamicGenerationSchema(type: String.self)),
                .init(name: "details", description: "Optional current evidence, note, or blocker detail", schema: DynamicGenerationSchema(type: String.self), isOptional: true)
            ]
        )
        return .objectSchema([
            .init(name: "title", description: "Short checklist title", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(
                name: "items",
                description: "Array of 1-12 checklist items with id, title, status, definitionOfDone, and optional details.",
                schema: DynamicGenerationSchema(arrayOf: itemSchema)
            )
        ])
    }

    func invoke(arguments: [String: JSONValue], context: ToolContext) async -> ToolInvocationResult {
        toolFailure(
            tool: name,
            code: "not_available",
            message: "`planning.progress_update` is handled by the active runtime turn and is only available in build mode.",
            retryable: false
        )
    }
}
