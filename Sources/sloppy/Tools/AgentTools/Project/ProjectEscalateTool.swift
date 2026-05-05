import AnyLanguageModel
import Foundation
import Logging
import Protocols

struct ProjectEscalateTool: CoreTool {
    let domain = "project"
    let title = "Escalate to user"
    let status = "fully_functional"
    let name = "project.escalate_to_user"
    let description = "Escalate a task or issue to the human user with a reason, sending a notification to the channel."

    var parameters: GenerationSchema {
        .objectSchema([
            .init(name: "reason", description: "Escalation reason", schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "taskId", description: "Optional related task ID", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "channelId", description: "Target channel ID (defaults to current session)", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "topicId", description: "Optional topic scoping", schema: DynamicGenerationSchema(type: String.self), isOptional: true)
        ])
    }

    func invoke(arguments: [String: JSONValue], context: ToolContext) async -> ToolInvocationResult {
        guard let svc = context.projectService else {
            return toolFailure(tool: name, code: "not_available", message: "Project service not available.", retryable: false)
        }
        let channelId = stringArgument(arguments, "channelId", default: context.sessionID)
        let reason = arguments["reason"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Escalation requested"
        let taskId = arguments["taskId"]?.asString

        let message = "Escalation: \(reason)"
        await context.runtime.appendSystemMessage(channelId: channelId, content: message)
        await svc.deliverMessage(channelId: channelId, content: message)

        if let taskId {
            let topicId = trimmedStringArgument(arguments, "topicId")
            if let project = await svc.findProjectForChannel(channelId: channelId, topicId: topicId) {
                _ = try? await svc.updateTask(
                    projectID: project.id,
                    taskID: taskId,
                    request: ProjectTaskUpdateRequest(status: ProjectTaskStatus.blocked.rawValue)
                )
            }
        }

        context.logger.info(
            "tool.escalate_to_user",
            metadata: [
                "channel_id": .string(channelId),
                "reason": .string(reason),
                "task_id": .string(taskId ?? "")
            ]
        )

        return toolSuccess(tool: name, data: .object([
            "escalated": .bool(true),
            "channelId": .string(channelId),
            "reason": .string(reason)
        ]))
    }
}
