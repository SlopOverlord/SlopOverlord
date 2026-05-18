import AnyLanguageModel
import Foundation
import Protocols

struct ProjectListTool: CoreTool {
    let domain = "project"
    let title = "List projects"
    let status = "fully_functional"
    let name = "project.list"
    let description = "List all dashboard projects with their channels and summary info."

    var parameters: GenerationSchema {
        .objectSchema([])
    }

    func invoke(arguments: [String: JSONValue], context: ToolContext) async -> ToolInvocationResult {
        guard let svc = context.projectService else {
            return toolFailure(tool: name, code: "not_available", message: "Project service not available.", retryable: false)
        }

        let projects = await svc.listAllProjects()
        let items: [JSONValue] = projects.map { project in
            .object([
                "id": .string(project.id),
                "name": .string(project.name),
                "description": .string(project.description),
                "icon": project.icon.map { .string($0) } ?? .null,
                "isFavorite": .bool(project.isFavorite),
                "channels": .array(project.channels.map { ch in
                    .object([
                        "channelId": .string(ch.channelId),
                        "title": .string(ch.title)
                    ])
                }),
                "taskCount": .number(Double(project.tasks.count)),
                "actors": .array(project.actors.map { .string($0) }),
                "teams": .array(project.teams.map { .string($0) }),
                "createdAt": .string(ISO8601DateFormatter().string(from: project.createdAt)),
                "updatedAt": .string(ISO8601DateFormatter().string(from: project.updatedAt))
            ])
        }

        return toolSuccess(tool: name, data: .object([
            "projects": .array(items),
            "total": .number(Double(projects.count))
        ]))
    }
}
