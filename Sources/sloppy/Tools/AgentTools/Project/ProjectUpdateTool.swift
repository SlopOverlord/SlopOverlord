import AnyLanguageModel
import Foundation
import Protocols

struct ProjectUpdateTool: CoreTool {
    let domain = "project"
    let title = "Update project"
    let status = "fully_functional"
    let name = "project.update"
    let description = "Update an existing dashboard project by ID. Only provided fields are changed."

    var parameters: GenerationSchema {
        .objectSchema([
            .init(name: "projectId", description: "Project ID to update", schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "name", description: "New project name", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "description", description: "New project description", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "icon", description: "New project icon", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "actors", description: "Updated list of actor IDs", schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self)), isOptional: true),
            .init(name: "teams", description: "Updated list of team IDs", schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self)), isOptional: true),
            .init(name: "repoPath", description: "Repository path", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "isFavorite", description: "Whether the project is pinned to favorites", schema: DynamicGenerationSchema(type: Bool.self), isOptional: true),
        ])
    }

    func invoke(arguments: [String: JSONValue], context: ToolContext) async -> ToolInvocationResult {
        guard let svc = context.projectService else {
            return toolFailure(tool: name, code: "not_available", message: "Project service not available.", retryable: false)
        }

        let projectId = arguments["projectId"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !projectId.isEmpty else {
            return toolFailure(tool: name, code: "invalid_arguments", message: "`projectId` is required.", retryable: false)
        }

        let actors = arguments["actors"]?.asArray?.compactMap(\.asString)
        let teams = arguments["teams"]?.asArray?.compactMap(\.asString)

        do {
            let project = try await svc.updateProject(
                projectID: projectId,
                request: ProjectUpdateRequest(
                    name: arguments["name"]?.asString,
                    description: arguments["description"]?.asString,
                    icon: arguments["icon"]?.asString,
                    actors: actors,
                    teams: teams,
                    repoPath: arguments["repoPath"]?.asString,
                    isFavorite: arguments["isFavorite"]?.asBool
                )
            )
            return toolSuccess(tool: name, data: .object([
                "projectId": .string(project.id),
                "name": .string(project.name),
                "description": .string(project.description),
                "updatedAt": .string(ISO8601DateFormatter().string(from: project.updatedAt))
            ]))
        } catch {
            return toolFailure(tool: name, code: "update_failed", message: "Failed to update project: \(error.localizedDescription)", retryable: true)
        }
    }
}
