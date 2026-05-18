import AnyLanguageModel
import Foundation
import Protocols

struct ProjectTaskCreateTool: CoreTool {
    let domain = "project"
    let title = "Create project task"
    let status = "fully_functional"
    let name = "project.task_create"
    let description = "Create a new task in the project associated with the current channel. If unsure which project is current, call project.current first and pass the returned projectId explicitly. For planning tasks, first call project.task_list and compare existing active tasks by intent, goal, scope, and expected outcome. If a similar task already exists, use project.task_update to add missing details instead of creating a duplicate."

    var parameters: GenerationSchema {
        .objectSchema([
            .init(name: "title", description: "Task title", schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "description", description: "Task description. For planning or pending_approval tasks, provide a structured markdown brief with ## Goal, ## Context, ## Definition of Done, and ## Tests / Verification, preserving the full planning handoff rather than a short summary.", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "priority", description: "Task priority: low, medium, high", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "status", description: "Initial task status", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "kind", description: "Task kind: planning, execution, bugfix", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "loopModeOverride", description: "Override loop mode: human or agent", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "parentTaskId", description: "Parent task ID (e.g. 'SLOPPY-123')", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "actorId", description: "Assigned actor ID", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "teamId", description: "Assigned team ID", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
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
        let title = arguments["title"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else {
            return toolFailure(tool: name, code: "invalid_arguments", message: "`title` is required.", retryable: false)
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
            let kind = arguments["kind"]?.asString.flatMap { ProjectTaskKind(rawValue: $0) }
            let loopMode = arguments["loopModeOverride"]?.asString.flatMap { ProjectLoopMode(rawValue: $0) }
            let description = arguments["description"]?.asString
            let taskStatus = trimmedStringArgument(arguments, "status") ?? ProjectTaskStatus.pendingApproval.rawValue
            if planningTaskBriefIsRequired(kind: kind, status: taskStatus) {
                let missingHeadings = missingRequiredPlanningTaskBriefHeadings(in: description)
                if !missingHeadings.isEmpty {
                    return planningTaskBriefValidationFailure(tool: name, missingHeadings: missingHeadings)
                }
            }
            let updated = try await svc.createTask(
                projectID: project.id,
                request: ProjectTaskCreateRequest(
                    title: title,
                    description: description,
                    priority: trimmedStringArgument(arguments, "priority") ?? "medium",
                    status: taskStatus,
                    kind: kind,
                    loopModeOverride: loopMode,
                    actorId: arguments["actorId"]?.asString,
                    teamId: arguments["teamId"]?.asString,
                    parentTaskId: arguments["parentTaskId"]?.asString
                )
            )
            let created = updated.tasks.last
            return toolSuccess(tool: name, data: .object([
                "projectId": .string(updated.id),
                "taskId": .string(created?.id ?? ""),
                "title": .string(created?.title ?? title),
                "status": .string(created?.status ?? "")
            ]))
        } catch {
            return toolFailure(tool: name, code: "create_failed", message: "Failed to create task.", retryable: true)
        }
    }
}
