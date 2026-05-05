import AnyLanguageModel
import Foundation
import Protocols

struct ProjectTaskUpdateTool: CoreTool {
    let domain = "project"
    let title = "Update project task"
    let status = "fully_functional"
    let name = "project.task_update"
    let description = "Update an existing task in the current channel project. Accepts taskId or reference plus partial fields."

    var parameters: GenerationSchema {
        .objectSchema([
            .init(name: "taskId", description: "Task ID to update", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "reference", description: "Task reference (alternative to taskId)", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "title", description: "New title", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "description", description: "New description", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "priority", description: "New priority", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "status", description: "New status", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "completionConfidence", description: "Required when setting status to done. Use done only if you verified the task is complete; otherwise use blocked, waiting_input, or unsure.", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "completionNote", description: "Required when setting status to done. Brief evidence for why the task is complete.", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "kind", description: "Task kind: planning, execution, bugfix", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "loopModeOverride", description: "Override loop mode: human or agent", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "actorId", description: "New assigned actor ID", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "teamId", description: "New assigned team ID", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "projectId", description: "Project ID (e.g. 'sloppy'), NOT a task ID like 'SLOPPY-4'. Use instead of channelId when known.", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
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
        let rawReference = arguments["taskId"]?.asString ?? arguments["reference"]?.asString ?? ""

        guard let normalizedReference = normalizeTaskRef(rawReference) else {
            return toolFailure(tool: name, code: "invalid_arguments", message: "`taskId` (or `reference`) is required.", retryable: false)
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

        do {
            let task = try findTask(reference: normalizedReference, in: project)
            let completionConfidenceRaw = arguments["completionConfidence"]?.asString?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let completionNote = arguments["completionNote"]?.asString?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let requestedStatus = trimmedStringArgument(arguments, "status")?.lowercased()
            if requestedStatus == ProjectTaskStatus.done.rawValue {
                guard let completionConfidenceRaw,
                      let completionConfidence = ProjectTaskCompletionConfidence(rawValue: completionConfidenceRaw),
                      let completionNote,
                      !completionNote.isEmpty
                else {
                    return toolFailure(
                        tool: name,
                        code: "completion_confirmation_required",
                        message: "Setting status to done requires `completionConfidence` and `completionNote`.",
                        retryable: true,
                        hint: "If the task is not actually complete, call this tool again with status `blocked` or `waiting_input` instead."
                    )
                }
                guard completionConfidence == .done else {
                    return toolFailure(
                        tool: name,
                        code: "completion_confirmation_mismatch",
                        message: "Use status `done` only when `completionConfidence` is `done`.",
                        retryable: true,
                        hint: "If completionConfidence is `blocked`, `waiting_input`, or `unsure`, call the tool again with that task status instead of `done`."
                    )
                }
            }
            let kind = arguments["kind"]?.asString.flatMap { ProjectTaskKind(rawValue: $0) }
            let loopMode = arguments["loopModeOverride"]?.asString.flatMap { ProjectLoopMode(rawValue: $0) }
            let updatedProject = try await svc.updateTask(
                projectID: project.id,
                taskID: task.id,
                request: ProjectTaskUpdateRequest(
                    title: arguments["title"]?.asString,
                    description: arguments["description"]?.asString,
                    priority: trimmedStringArgument(arguments, "priority"),
                    status: requestedStatus,
                    completionConfidence: completionConfidenceRaw.flatMap { ProjectTaskCompletionConfidence(rawValue: $0) },
                    completionNote: completionNote,
                    kind: kind,
                    loopModeOverride: loopMode,
                    actorId: arguments["actorId"]?.asString,
                    teamId: arguments["teamId"]?.asString,
                    changedBy: context.agentID.isEmpty ? "agent" : "agent:\(context.agentID)"
                )
            )
            let updatedTask = updatedProject.tasks.first(where: { $0.id == task.id }) ?? task
            return toolSuccess(tool: name, data: .object([
                "projectId": .string(updatedProject.id),
                "taskId": .string(updatedTask.id),
                "status": .string(updatedTask.status),
                "task": taskJSONValue(updatedTask)
            ]))
        } catch CoreService.ProjectError.notFound {
            return toolFailure(tool: name, code: "task_not_found", message: "Task `\(normalizedReference)` was not found.", retryable: false)
        } catch {
            return toolFailure(tool: name, code: "update_failed", message: "Failed to update task.", retryable: true)
        }
    }
}
