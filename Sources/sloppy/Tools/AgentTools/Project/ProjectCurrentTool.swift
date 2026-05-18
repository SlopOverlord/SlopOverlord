import AnyLanguageModel
import Foundation
import PluginSDK
import Protocols

struct ProjectCurrentTool: CoreTool {
    let domain = "project"
    let title = "Get current project"
    let status = "fully_functional"
    let name = "project.current"
    let description = "Return the project associated with the current session/channel. Use this before creating or updating tasks when you are unsure which project is current."

    var parameters: GenerationSchema {
        .objectSchema([
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
        guard let project = await svc.findProjectForChannel(channelId: channelId, topicId: topicId) else {
            return toolFailure(tool: name, code: "project_not_found", message: "No project found for this channel.", retryable: false)
        }

        let scoped = ChannelGatewayScope.parse(channelId)
        let effectiveChannelId = ChannelGatewayScope.scopedChannelId(
            baseChannelId: scoped.baseChannelId,
            topicKey: scoped.topicKey ?? topicId
        )
        let matchedChannel = project.channels.first { $0.channelId == effectiveChannelId }
            ?? project.channels.first { binding in
                ChannelGatewayScope.sessionMatchesBinding(sessionChannelId: effectiveChannelId, bindingChannelId: binding.channelId)
            }

        return toolSuccess(tool: name, data: projectCurrentJSONValue(
            project,
            requestedChannelId: channelId,
            effectiveChannelId: effectiveChannelId,
            matchedChannel: matchedChannel,
            topicId: topicId
        ))
    }
}

private func projectCurrentJSONValue(
    _ project: ProjectRecord,
    requestedChannelId: String,
    effectiveChannelId: String,
    matchedChannel: ProjectChannel?,
    topicId: String?
) -> JSONValue {
    .object([
        "projectId": .string(project.id),
        "projectName": .string(project.name),
        "description": .string(project.description),
        "icon": project.icon.map { .string($0) } ?? .null,
        "isFavorite": .bool(project.isFavorite),
        "channelId": .string(requestedChannelId),
        "effectiveChannelId": .string(effectiveChannelId),
        "matchedChannelId": matchedChannel.map { .string($0.channelId) } ?? .null,
        "matchedChannelTitle": matchedChannel.map { .string($0.title) } ?? .null,
        "topicId": topicId.map { .string($0) } ?? .null,
        "taskCount": .number(Double(project.tasks.count)),
        "actors": .array(project.actors.map { .string($0) }),
        "teams": .array(project.teams.map { .string($0) }),
        "repoPath": project.repoPath.map { .string($0) } ?? .null,
        "taskLoopMode": .string(project.taskLoopMode.rawValue),
        "channels": .array(project.channels.map { ch in
            .object([
                "id": .string(ch.id),
                "channelId": .string(ch.channelId),
                "title": .string(ch.title)
            ])
        }),
        "createdAt": .string(ISO8601DateFormatter().string(from: project.createdAt)),
        "updatedAt": .string(ISO8601DateFormatter().string(from: project.updatedAt))
    ])
}
