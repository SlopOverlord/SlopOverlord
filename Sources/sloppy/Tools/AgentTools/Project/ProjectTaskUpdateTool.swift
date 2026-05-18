import AnyLanguageModel
import Foundation
import Protocols

struct ProjectTaskUpdateTool: CoreTool {
    let domain = "project"
    let title = "Update project task"
    let status = "fully_functional"
    let name = "project.task_update"
    let description = "Update an existing task in the current channel project. Accepts taskId or reference plus partial fields. If unsure which project is current, call project.current first and pass the returned projectId explicitly."

    var parameters: GenerationSchema {
        .objectSchema([
            .init(name: "taskId", description: "Task ID to update", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "reference", description: "Task reference (alternative to taskId)", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "title", description: "New title", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "description", description: "New description. For planning or pending_approval tasks, provide a structured markdown brief with ## Goal, ## Context, ## Definition of Done, and ## Tests / Verification, preserving the full planning handoff rather than a short summary.", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
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
            let updatedDescription = arguments["description"]?.asString ?? task.description
            let updatedKind = kind ?? task.kind
            let updatedStatus = requestedStatus ?? task.status
            if planningTaskBriefIsRequired(kind: updatedKind, status: updatedStatus) {
                let missingHeadings = missingRequiredPlanningTaskBriefHeadings(in: updatedDescription)
                if !missingHeadings.isEmpty {
                    return planningTaskBriefValidationFailure(tool: name, missingHeadings: missingHeadings)
                }
            }
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
            if task.status != updatedTask.status,
               updatedTask.status == ProjectTaskStatus.done.rawValue || updatedTask.status == ProjectTaskStatus.needsReview.rawValue {
                await svc.requestProjectMemoryCheckpoint(
                    agentID: context.agentID,
                    sessionID: context.sessionID,
                    projectID: updatedProject.id,
                    taskID: updatedTask.id,
                    status: updatedTask.status
                )
            }
            return toolSuccess(tool: name, data: .object([
                "projectId": .string(updatedProject.id),
                "taskId": .string(updatedTask.id),
                "status": .string(updatedTask.status),
                "task": taskJSONValue(updatedTask)
            ]))
        } catch let error as CoreService.ProjectError {
            return projectUpdateFailure(error: error, normalizedReference: normalizedReference)
        } catch {
            return toolFailure(tool: name, code: "update_failed", message: "Failed to update task.", retryable: true)
        }
    }

    private func projectUpdateFailure(error: CoreService.ProjectError, normalizedReference: String) -> ToolInvocationResult {
        switch error {
        case .invalidProjectID:
            return toolFailure(tool: name, code: "invalid_arguments", message: "Project ID is invalid.", retryable: false)
        case .invalidChannelID:
            return toolFailure(tool: name, code: "invalid_arguments", message: "Channel ID is invalid.", retryable: false)
        case .invalidTaskID:
            return toolFailure(tool: name, code: "invalid_arguments", message: "Task ID is invalid.", retryable: false)
        case .invalidPayload:
            return toolFailure(
                tool: name,
                code: "invalid_payload",
                message: "Task update payload is invalid.",
                retryable: false,
                hint: "Allowed fields include title, description, priority, status, kind, loopModeOverride, actorId, and teamId. Allowed status values are pending_approval, backlog, ready, in_progress, waiting_input, done, blocked, needs_review, and cancelled."
            )
        case .notFound:
            return toolFailure(tool: name, code: "task_not_found", message: "Task `\(normalizedReference)` was not found.", retryable: false)
        case .conflict:
            return toolFailure(tool: name, code: "project_conflict", message: "Project update conflicted with the current project state.", retryable: false)
        }
    }
}
