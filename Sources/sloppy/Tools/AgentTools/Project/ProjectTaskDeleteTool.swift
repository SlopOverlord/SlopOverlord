import AnyLanguageModel
import Foundation
import Protocols

struct ProjectTaskDeleteTool: CoreTool {
    let domain = "project"
    let title = "Delete project task"
    let status = "fully_functional"
    let name = "project.task_delete"
    let description = "Delete one or more tasks from the current channel project."

    var parameters: GenerationSchema {
        .objectSchema([
            .init(name: "taskId", description: "Task ID to delete", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "reference", description: "Task reference (alternative to taskId)", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "taskIds", description: "Task IDs to delete in one call", schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self)), isOptional: true),
            .init(name: "references", description: "Task references to delete in one call", schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self)), isOptional: true),
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
        let parsedReferences = taskReferences(from: arguments)

        guard parsedReferences.invalid.isEmpty else {
            return toolFailure(tool: name, code: "invalid_arguments", message: "Task references must be strings using letters, numbers, dashes, underscores, or dots.", retryable: false)
        }
        guard !parsedReferences.references.isEmpty else {
            return toolFailure(tool: name, code: "invalid_arguments", message: "`taskId`, `reference`, `taskIds`, or `references` is required.", retryable: false)
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
            let tasks = try parsedReferences.references.map { try findTask(reference: $0, in: project) }
            var updatedProject = project
            for task in tasks {
                updatedProject = try await svc.deleteTask(projectID: project.id, taskID: task.id)
            }
            var data: [String: JSONValue] = [
                "projectId": .string(updatedProject.id),
                "taskIds": .array(tasks.map { .string($0.id) }),
                "deletedCount": .number(Double(tasks.count))
            ]
            if let firstTask = tasks.first, tasks.count == 1 {
                data["taskId"] = .string(firstTask.id)
            }
            return toolSuccess(tool: name, data: .object(data))
        } catch CoreService.ProjectError.notFound {
            return toolFailure(tool: name, code: "task_not_found", message: "One or more tasks were not found.", retryable: false)
        } catch {
            return toolFailure(tool: name, code: "delete_failed", message: "Failed to delete task.", retryable: true)
        }
    }
}
