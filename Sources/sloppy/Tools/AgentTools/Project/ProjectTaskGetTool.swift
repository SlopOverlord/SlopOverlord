import AnyLanguageModel
import Foundation
import Protocols

struct ProjectTaskGetTool: CoreTool {
    let domain = "project"
    let title = "Get project task"
    let status = "fully_functional"
    let name = "project.task_get"
    let description = "Get full task details by readable id (for example, MOBILE-1). Accepts taskId or reference."

    var parameters: GenerationSchema {
        .objectSchema([
            .init(name: "taskId", description: "Readable task ID (e.g. MOBILE-1)", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "reference", description: "Task reference (alternative to taskId)", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "channelId", description: "Fallback channel ID", schema: DynamicGenerationSchema(type: String.self), isOptional: true)
        ])
    }

    func invoke(arguments: [String: JSONValue], context: ToolContext) async -> ToolInvocationResult {
        guard let svc = context.projectService else {
            return toolFailure(tool: name, code: "not_available", message: "Project service not available.", retryable: false)
        }
        let rawReference = arguments["taskId"]?.asString ?? arguments["reference"]?.asString ?? ""
        let fallbackChannelId = stringArgument(arguments, "channelId", default: context.sessionID)

        guard let normalizedReference = normalizeTaskRef(rawReference) else {
            return toolFailure(tool: name, code: "invalid_arguments", message: "`taskId` (or `reference`) is required. Example: MOBILE-1", retryable: false)
        }

        do {
            let record = try await svc.getTask(reference: normalizedReference)
            return toolSuccess(tool: name, data: .object([
                "projectId": .string(record.projectId),
                "projectName": .string(record.projectName),
                "task": taskJSONValue(record.task),
                "taskId": .string(record.task.id)
            ]))
        } catch CoreService.ProjectError.notFound {
            return ToolInvocationResult(
                tool: name,
                ok: false,
                data: .object([
                    "channelId": .string(fallbackChannelId),
                    "taskId": .string(normalizedReference)
                ]),
                error: ToolErrorPayload(code: "task_not_found", message: "Task `\(normalizedReference)` was not found.", retryable: false)
            )
        } catch {
            return toolFailure(tool: name, code: "read_failed", message: "Failed to fetch task details.", retryable: true)
        }
    }
}
