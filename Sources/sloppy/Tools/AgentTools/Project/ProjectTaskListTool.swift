import AnyLanguageModel
import Foundation
import Protocols

struct ProjectTaskListTool: CoreTool {
    let domain = "project"
    let title = "List project tasks"
    let status = "fully_functional"
    let name = "project.task_list"
    let description = "List tasks for the project associated with the current channel."

    var parameters: GenerationSchema {
        .objectSchema([
            .init(name: "projectId", description: "Project ID (e.g. 'sloppy'), NOT a task ID like 'SLOPPY-4'. Use instead of channelId when known.", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "channelId", description: "Channel ID (defaults to current session)", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "status", description: "Filter by task status", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "topicId", description: "Optional topic scoping", schema: DynamicGenerationSchema(type: String.self), isOptional: true)
        ])
    }

    func invoke(arguments: [String: JSONValue], context: ToolContext) async -> ToolInvocationResult {
        guard let svc = context.projectService else {
            return toolFailure(tool: name, code: "not_available", message: "Project service not available.", retryable: false)
        }
        let channelId = stringArgument(arguments, "channelId", default: context.sessionID)
        let topicId = trimmedStringArgument(arguments, "topicId")
        let statusFilter = trimmedStringArgument(arguments, "status")?.lowercased()

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

        var tasks = project.tasks
        if let statusFilter, !statusFilter.isEmpty {
            tasks = tasks.filter { $0.status == statusFilter }
        }

        let items: [JSONValue] = tasks.map { task in
            .object([
                "id": .string(task.id),
                "title": .string(task.title),
                "status": .string(task.status),
                "priority": .string(task.priority),
                "actorId": task.actorId.map { .string($0) } ?? .null,
                "teamId": task.teamId.map { .string($0) } ?? .null,
                "claimedActorId": task.claimedActorId.map { .string($0) } ?? .null
            ])
        }

        return toolSuccess(tool: name, data: .object([
            "projectId": .string(project.id),
            "projectName": .string(project.name),
            "tasks": .array(items)
        ]))
    }
}
