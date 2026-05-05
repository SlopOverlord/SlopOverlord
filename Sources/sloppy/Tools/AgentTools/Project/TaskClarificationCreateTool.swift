import AnyLanguageModel
import Foundation
import Protocols

struct TaskClarificationCreateTool: CoreTool {
    let domain = "project"
    let title = "Request task clarification"
    let status = "fully_functional"
    let name = "project.task_clarification_create"
    let description = "Create a clarification request for a project task when the agent needs input before proceeding."

    var parameters: GenerationSchema {
        .objectSchema([
            .init(name: "taskId", description: "Task ID to request clarification for", schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "questionText", description: "The question that needs to be answered", schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "options", description: "JSON array of option objects with id and label fields", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "allowNotes", description: "Whether freeform notes are allowed in the response", schema: DynamicGenerationSchema(type: Bool.self), isOptional: true),
            .init(name: "projectId", description: "Project ID. Use instead of channelId when known.", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "channelId", description: "Channel ID (defaults to current session)", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "topicId", description: "Optional topic scoping", schema: DynamicGenerationSchema(type: String.self), isOptional: true)
        ])
    }

    func invoke(arguments: [String: JSONValue], context: ToolContext) async -> ToolInvocationResult {
        guard let svc = context.projectService else {
            return toolFailure(tool: name, code: "not_available", message: "Project service not available.", retryable: false)
        }
        let channelId = stringArgument(arguments, "channelId", default: context.sessionID)
        let topicId = trimmedStringArgument(arguments, "topicId")
        let taskId = arguments["taskId"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let questionText = arguments["questionText"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !taskId.isEmpty else {
            return toolFailure(tool: name, code: "invalid_arguments", message: "`taskId` is required.", retryable: false)
        }
        guard !questionText.isEmpty else {
            return toolFailure(tool: name, code: "invalid_arguments", message: "`questionText` is required.", retryable: false)
        }

        let project: ProjectRecord
        if let pid = trimmedStringArgument(arguments, "projectId") {
            do {
                project = try await svc.getProject(id: pid)
            } catch {
                return toolFailure(tool: name, code: "project_not_found", message: "Project not found.", retryable: false)
            }
        } else {
            guard let found = await svc.findProjectForChannel(channelId: channelId, topicId: topicId) else {
                return toolFailure(tool: name, code: "project_not_found", message: "No project found for this channel.", retryable: false)
            }
            project = found
        }

        var options: [ClarificationOption]?
        if let optionsJSON = arguments["options"]?.asString,
           let data = optionsJSON.data(using: .utf8) {
            options = try? JSONDecoder().decode([ClarificationOption].self, from: data)
        }

        let allowNote = arguments["allowNotes"]?.asBool ?? true

        do {
            let record = try await svc.createTaskClarification(
                projectID: project.id,
                taskID: taskId,
                request: TaskClarificationCreateRequest(
                    questionText: questionText,
                    options: options ?? [],
                    allowNote: allowNote,
                    createdByAgentId: context.agentID
                )
            )
            return toolSuccess(tool: name, data: .object([
                "clarificationId": .string(record.id),
                "projectId": .string(record.projectId),
                "taskId": .string(record.taskId),
                "status": .string(record.status.rawValue),
                "targetType": .string(record.targetType.rawValue)
            ]))
        } catch {
            return toolFailure(tool: name, code: "create_failed", message: "Failed to create clarification: \(error.localizedDescription)", retryable: true)
        }
    }
}
