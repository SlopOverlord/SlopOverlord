import Foundation
import Protocols

// MARK: - Build Progress

extension CoreService {
    func handleAgentBuildProgressTool(
        agentID: String,
        sessionID: String,
        request: ToolInvocationRequest,
        chatMode: AgentChatMode?
    ) async -> ToolInvocationResult {
        guard chatMode == .build else {
            return ToolInvocationResult(
                tool: request.tool,
                ok: false,
                error: ToolErrorPayload(
                    code: "build_mode_required",
                    message: "`planning.progress_update` is only available in build mode.",
                    retryable: false
                )
            )
        }

        let progress: AgentBuildProgressEvent
        do {
            progress = try makeBuildProgressEvent(arguments: request.arguments)
        } catch {
            return ToolInvocationResult(
                tool: request.tool,
                ok: false,
                error: ToolErrorPayload(code: "invalid_arguments", message: String(describing: error), retryable: false)
            )
        }

        let event = AgentSessionEvent(
            agentId: agentID,
            sessionId: sessionID,
            type: .buildProgress,
            buildProgress: progress
        )

        do {
            let summary = try sessionStore.appendEvents(agentID: agentID, sessionID: sessionID, events: [event])
            publishLiveSessionEvents(agentID: agentID, sessionID: sessionID, summary: summary, events: [event])
            return ToolInvocationResult(
                tool: request.tool,
                ok: true,
                data: .object([
                    "progress": buildProgressJSON(progress),
                    "message": .string("Build progress recorded.")
                ])
            )
        } catch {
            return ToolInvocationResult(
                tool: request.tool,
                ok: false,
                error: ToolErrorPayload(code: "session_write_failed", message: "Failed to persist build progress.", retryable: true)
            )
        }
    }

    private func makeBuildProgressEvent(arguments: [String: JSONValue]) throws -> AgentBuildProgressEvent {
        let title = trimmedBuildProgressString(arguments["title"]) ?? "Progress"
        guard let itemValues = arguments["items"]?.asArray else {
            throw BuildProgressValidationError.invalid("`items` must be an array.")
        }
        guard !itemValues.isEmpty, itemValues.count <= 12 else {
            throw BuildProgressValidationError.invalid("Provide between 1 and 12 progress items.")
        }

        var seenIDs: Set<String> = []
        let items = try itemValues.map { value -> AgentBuildProgressItem in
            guard let object = value.asObject else {
                throw BuildProgressValidationError.invalid("Each progress item must be an object.")
            }
            guard let id = trimmedBuildProgressString(object["id"]) else {
                throw BuildProgressValidationError.invalid("Progress item is missing `id`.")
            }
            guard seenIDs.insert(id).inserted else {
                throw BuildProgressValidationError.invalid("Duplicate progress item id `\(id)`.")
            }
            guard let itemTitle = trimmedBuildProgressString(object["title"]) else {
                throw BuildProgressValidationError.invalid("Progress item `\(id)` is missing `title`.")
            }
            guard let statusRaw = trimmedBuildProgressString(object["status"]),
                  let status = AgentBuildProgressStatus(rawValue: statusRaw)
            else {
                throw BuildProgressValidationError.invalid("Progress item `\(id)` has an unknown `status`.")
            }
            guard let definitionOfDone = trimmedBuildProgressString(object["definitionOfDone"]) else {
                throw BuildProgressValidationError.invalid("Progress item `\(id)` is missing `definitionOfDone`.")
            }
            let details = trimmedBuildProgressString(object["details"])
            if status == .blocked, details == nil {
                throw BuildProgressValidationError.invalid("Blocked progress item `\(id)` must include `details`.")
            }
            return AgentBuildProgressItem(
                id: id,
                title: itemTitle,
                status: status,
                definitionOfDone: definitionOfDone,
                details: details
            )
        }

        return AgentBuildProgressEvent(title: title, items: items)
    }

    private func trimmedBuildProgressString(_ value: JSONValue?) -> String? {
        guard let raw = value?.asString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return nil
        }
        return raw
    }

    private func buildProgressJSON(_ progress: AgentBuildProgressEvent) -> JSONValue {
        .object([
            "title": .string(progress.title),
            "createdAt": .string(ISO8601DateFormatter().string(from: progress.createdAt)),
            "items": .array(progress.items.map { item in
                var object: [String: JSONValue] = [
                    "id": .string(item.id),
                    "title": .string(item.title),
                    "status": .string(item.status.rawValue),
                    "definitionOfDone": .string(item.definitionOfDone)
                ]
                if let details = item.details {
                    object["details"] = .string(details)
                }
                return .object(object)
            })
        ])
    }
}

private enum BuildProgressValidationError: Error, CustomStringConvertible {
    case invalid(String)

    var description: String {
        switch self {
        case .invalid(let message):
            return message
        }
    }
}
