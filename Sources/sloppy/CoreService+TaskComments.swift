import Foundation
import Protocols

// MARK: - Task Comments

extension CoreService {
    // MARK: - Task Comments

    public func listTaskComments(projectID: String, taskID: String) async -> [TaskComment] {
        let url = taskCommentsFileURL(projectID: projectID, taskID: taskID)
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([TaskComment].self, from: data)) ?? []
    }

    public func addTaskComment(projectID: String, taskID: String, request: TaskCommentCreateRequest) async -> TaskComment {
        var comments = await listTaskComments(projectID: projectID, taskID: taskID)
        let comment = TaskComment(
            id: UUID().uuidString,
            taskId: taskID,
            content: request.content,
            authorActorId: request.authorActorId,
            mentionedActorId: request.mentionedActorId
        )
        comments.append(comment)
        saveTaskComments(comments, projectID: projectID, taskID: taskID)
        await mirrorOutboundCommentIfNeeded(projectID: projectID, taskID: taskID, commentID: comment.id)

        if let mentionedActorId = request.mentionedActorId {
            let agents = (try? listAgents()) ?? []
            let board = (try? actorBoardStore.loadBoard(agents: agents))
            if let node = board?.nodes.first(where: { $0.id == mentionedActorId }),
               let agentID = node.linkedAgentId {
                let projects = await store.listProjects()
                if let project = projects.first(where: { $0.id == projectID }),
                   let task = project.tasks.first(where: { $0.id == taskID }) {
                    Task {
                        await self.handleAgentCommentReply(
                            projectID: projectID,
                            taskID: taskID,
                            task: task,
                            agentID: agentID,
                            comment: comment
                        )
                    }
                }
            }
        }

        return comment
    }

    public func deleteTaskComment(projectID: String, taskID: String, commentID: String) async -> Bool {
        var comments = await listTaskComments(projectID: projectID, taskID: taskID)
        let before = comments.count
        comments.removeAll { $0.id == commentID }
        if comments.count == before { return false }
        saveTaskComments(comments, projectID: projectID, taskID: taskID)
        return true
    }

    func taskCommentsFileURL(projectID: String, taskID: String) -> URL {
        projectMetaDirectoryURL(projectID: projectID)
            .appendingPathComponent("task-comments-\(taskID).json")
    }

    func saveTaskComments(_ comments: [TaskComment], projectID: String, taskID: String) {
        ensureProjectWorkspaceDirectory(projectID: projectID)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(comments) else { return }
        let url = taskCommentsFileURL(projectID: projectID, taskID: taskID)
        try? data.write(to: url, options: .atomic)
    }
    func handleAgentCommentReply(
        projectID: String,
        taskID: String,
        task: ProjectTask,
        agentID: String,
        comment: TaskComment
    ) async {
        let sessionTitle = "task-comment:\(projectID):\(taskID)"
        let existingSession: AgentSessionSummary?
        do {
            existingSession = try listAgentSessions(agentID: agentID)
                .first(where: { $0.title == sessionTitle })
        } catch {
            existingSession = nil
        }

        let session: AgentSessionSummary
        do {
            if let existing = existingSession {
                session = existing
            } else {
                session = try await createAgentSession(
                    agentID: agentID,
                    request: AgentSessionCreateRequest(title: sessionTitle, kind: .chat)
                )
            }
        } catch {
            logger.warning(
                "task.comment.agent_session_error",
                metadata: ["agent_id": .string(agentID), "task_id": .string(taskID), "error": .string(error.localizedDescription)]
            )
            return
        }

        let recentComments = await listTaskComments(projectID: projectID, taskID: taskID)
            .suffix(10)
            .map { c in "[\(c.authorActorId)]: \(c.content)" }
            .joined(separator: "\n")

        let contextPrompt = """
        You are responding to a comment in a task management system.

        Task: \(task.title)
        Status: \(task.status)
        Description: \(task.description.isEmpty ? "(none)" : task.description)

        Recent comments:
        \(recentComments.isEmpty ? "(none)" : recentComments)

        The user \(comment.authorActorId) has addressed you with:
        \(comment.content)

        Please respond concisely and helpfully.
        """

        let response: AgentSessionMessageResponse
        do {
            response = try await postAgentSessionMessage(
                agentID: agentID,
                sessionID: session.id,
                request: AgentSessionPostMessageRequest(
                    userId: "system_task_comment",
                    content: contextPrompt
                )
            )
        } catch {
            logger.warning(
                "task.comment.agent_reply_error",
                metadata: ["agent_id": .string(agentID), "task_id": .string(taskID), "error": .string(error.localizedDescription)]
            )
            return
        }

        let replyText = response.appendedEvents
            .filter { $0.type == .message && $0.message?.role == .assistant }
            .compactMap { $0.message?.segments }
            .flatMap { $0 }
            .compactMap { $0.text }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !replyText.isEmpty else {
            return
        }

        var comments = await listTaskComments(projectID: projectID, taskID: taskID)
        let reply = TaskComment(
            id: UUID().uuidString,
            taskId: taskID,
            content: replyText,
            authorActorId: agentID,
            mentionedActorId: comment.authorActorId,
            isAgentReply: true
        )
        comments.append(reply)
        saveTaskComments(comments, projectID: projectID, taskID: taskID)
    }

}
