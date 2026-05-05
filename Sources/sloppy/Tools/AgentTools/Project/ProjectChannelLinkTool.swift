import AnyLanguageModel
import Foundation
import Protocols

struct ProjectChannelLinkTool: CoreTool {
    let domain = "project"
    let title = "Link channel to project"
    let status = "fully_functional"
    let name = "project.channel_link"
    let description = "Link the current channel, Telegram topic, Discord room, or a provided channel ID to a dashboard project."

    var parameters: GenerationSchema {
        .objectSchema([
            .init(name: "projectId", description: "Project ID. Use this when known.", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "projectName", description: "Project name to resolve when projectId is unknown. Must match exactly one project.", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "channelId", description: "Channel ID to link. Defaults to the current channel/session.", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "title", description: "Display title for this project channel.", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
        ])
    }

    func invoke(arguments: [String: JSONValue], context: ToolContext) async -> ToolInvocationResult {
        guard let svc = context.projectService else {
            return toolFailure(tool: name, code: "not_available", message: "Project service not available.", retryable: false)
        }

        let projects = await svc.listAllProjects().filter { !$0.isArchived }
        let projectId = arguments["projectId"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let projectName = arguments["projectName"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedProject: ProjectRecord?

        if !projectId.isEmpty {
            resolvedProject = projects.first { $0.id.caseInsensitiveCompare(projectId) == .orderedSame }
        } else if !projectName.isEmpty {
            let needle = projectName.lowercased()
            let matches = projects.filter {
                $0.name.lowercased() == needle || $0.id.lowercased() == needle
            }
            guard matches.count <= 1 else {
                return toolFailure(
                    tool: name,
                    code: "ambiguous_project",
                    message: "More than one project matches '\(projectName)'. Use projectId.",
                    retryable: false
                )
            }
            resolvedProject = matches.first
        } else {
            return toolFailure(tool: name, code: "project_required", message: "Provide projectId or projectName.", retryable: false)
        }

        guard let project = resolvedProject else {
            return toolFailure(tool: name, code: "project_not_found", message: "Project not found.", retryable: false)
        }

        let channelId = stringArgument(arguments, "channelId", default: context.sessionID)
        guard !channelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return toolFailure(tool: name, code: "channel_required", message: "Channel ID is required.", retryable: false)
        }

        do {
            let result = try await svc.linkProjectChannel(
                projectID: project.id,
                request: ProjectChannelLinkRequest(
                    channelId: channelId,
                    title: arguments["title"]?.asString,
                    ensureSession: true
                )
            )
            return toolSuccess(tool: name, data: .object([
                "status": .string(result.status),
                "projectId": .string(result.project.id),
                "projectName": .string(result.project.name),
                "channelId": .string(result.channel.channelId),
                "channelTitle": .string(result.channel.title),
                "sessionId": result.session.map { .string($0.sessionId) } ?? .null
            ]))
        } catch let conflict as CoreService.ProjectChannelLinkConflict {
            return toolFailure(
                tool: name,
                code: "channel_already_linked",
                message: "Channel is already linked to project '\(conflict.ownerProjectName)' (\(conflict.ownerProjectId)).",
                retryable: false
            )
        } catch {
            return toolFailure(tool: name, code: "link_failed", message: "Failed to link channel: \(error.localizedDescription)", retryable: true)
        }
    }
}
