import Foundation
import Protocols

// MARK: - Task Activity

extension CoreService {
    public func listTaskActivities(projectID: String, taskID: String) async -> [TaskActivity] {
        let url = taskActivitiesFileURL(projectID: projectID, taskID: taskID)
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([TaskActivity].self, from: data)) ?? []
    }

    public func recordTaskActivity(
        projectID: String,
        taskID: String,
        field: TaskActivityField,
        oldValue: String?,
        newValue: String?,
        actorId: String
    ) async {
        var activities = await listTaskActivities(projectID: projectID, taskID: taskID)
        let activity = TaskActivity(
            id: UUID().uuidString,
            taskId: taskID,
            field: field,
            oldValue: oldValue,
            newValue: newValue,
            actorId: actorId
        )
        activities.append(activity)
        saveTaskActivities(activities, projectID: projectID, taskID: taskID)
    }

    func taskActivitiesFileURL(projectID: String, taskID: String) -> URL {
        projectMetaDirectoryURL(projectID: projectID)
            .appendingPathComponent("task-activities-\(taskID).json")
    }

    func saveTaskActivities(_ activities: [TaskActivity], projectID: String, taskID: String) {
        ensureProjectWorkspaceDirectory(projectID: projectID)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(activities) else { return }
        let url = taskActivitiesFileURL(projectID: projectID, taskID: taskID)
        try? data.write(to: url, options: .atomic)
    }

    func recordSystemStatusChange(
        projectID: String,
        taskID: String,
        from oldStatus: String,
        to newStatus: String,
        source: String
    ) async {
        guard oldStatus != newStatus else { return }
        await recordTaskActivity(
            projectID: projectID, taskID: taskID,
            field: .status, oldValue: oldStatus, newValue: newStatus, actorId: source
        )
        await emitTaskStatusNotificationIfNeeded(
            projectID: projectID,
            taskID: taskID,
            status: newStatus,
            source: source
        )
    }

    func emitTaskStatusNotificationIfNeeded(
        projectID: String,
        taskID: String,
        status: String,
        source: String
    ) async {
        guard let taskStatus = ProjectTaskStatus(rawValue: status) else {
            return
        }
        guard let project = await store.project(id: projectID),
              let task = project.tasks.first(where: { $0.id == taskID })
        else {
            return
        }

        let message = "\(task.id): \(task.title)"
        switch taskStatus {
        case .done:
            await notificationService.pushTaskCompleted(
                title: "Task completed",
                message: message,
                taskId: task.id,
                projectId: project.id,
                source: source
            )
        case .waitingInput:
            await notificationService.pushInputRequired(
                title: "Input required",
                message: message,
                taskId: task.id,
                projectId: project.id,
                source: source
            )
        case .needsReview:
            await notificationService.pushInputRequired(
                title: "Task needs review",
                message: message,
                taskId: task.id,
                projectId: project.id,
                source: source
            )
        case .blocked:
            await notificationService.push(DashboardNotification(
                type: .agentError,
                title: "Task blocked",
                message: message,
                metadata: [
                    "taskId": task.id,
                    "projectId": project.id,
                    "source": source
                ]
            ))
        case .pendingApproval, .backlog, .ready, .inProgress, .cancelled:
            break
        }
    }

    func markTaskWaitingInputForAgentSession(
        agentID: String,
        sessionID: String,
        reason: String,
        source: String
    ) async {
        guard let taskID = taskIDForAgentSession(agentID: agentID, sessionID: sessionID) else {
            return
        }
        let projects = await store.listProjects()
        for var project in projects {
            guard let taskIndex = project.tasks.firstIndex(where: { $0.id == taskID }) else {
                continue
            }
            var task = project.tasks[taskIndex]
            let previousStatus = task.status
            guard ProjectTaskStatus(rawValue: previousStatus)?.isTerminal != true,
                  previousStatus != ProjectTaskStatus.waitingInput.rawValue
            else {
                return
            }
            task.status = ProjectTaskStatus.waitingInput.rawValue
            task.updatedAt = Date()
            let note = "Waiting for user input: \(reason)"
            if task.description.isEmpty {
                task.description = note
            } else if !task.description.contains(note) {
                task.description += "\n\n\(note)"
            }
            project.tasks[taskIndex] = task
            project.updatedAt = Date()
            await store.saveProject(project)
            await kanbanEventService.push(KanbanEvent(type: .taskUpdated, projectId: project.id, task: task))
            await recordSystemStatusChange(
                projectID: project.id,
                taskID: task.id,
                from: previousStatus,
                to: task.status,
                source: source
            )
            return
        }
    }

    func taskIDForAgentSession(agentID: String, sessionID: String) -> String? {
        guard let detail = try? sessionStore.loadSession(agentID: agentID, sessionID: sessionID) else {
            return nil
        }
        let prefix = "task-"
        guard detail.summary.title.hasPrefix(prefix) else {
            return nil
        }
        let taskID = String(detail.summary.title.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return taskID.isEmpty ? nil : taskID
    }

    func recordTaskFieldChanges(
        projectID: String,
        taskID: String,
        oldTask: ProjectTask,
        newTask: ProjectTask,
        changedBy: String
    ) async {
        if oldTask.status != newTask.status {
            await recordTaskActivity(
                projectID: projectID, taskID: taskID,
                field: .status, oldValue: oldTask.status, newValue: newTask.status, actorId: changedBy
            )
        }
        if oldTask.priority != newTask.priority {
            await recordTaskActivity(
                projectID: projectID, taskID: taskID,
                field: .priority, oldValue: oldTask.priority, newValue: newTask.priority, actorId: changedBy
            )
        }
        let oldAssignee = oldTask.actorId ?? oldTask.teamId ?? ""
        let newAssignee = newTask.actorId ?? newTask.teamId ?? ""
        if oldAssignee != newAssignee {
            await recordTaskActivity(
                projectID: projectID, taskID: taskID,
                field: .assignee,
                oldValue: oldAssignee.isEmpty ? nil : oldAssignee,
                newValue: newAssignee.isEmpty ? nil : newAssignee,
                actorId: changedBy
            )
        }
        if oldTask.title != newTask.title {
            await recordTaskActivity(
                projectID: projectID, taskID: taskID,
                field: .title, oldValue: oldTask.title, newValue: newTask.title, actorId: changedBy
            )
        }
        if oldTask.description != newTask.description {
            await recordTaskActivity(
                projectID: projectID, taskID: taskID,
                field: .description, oldValue: oldTask.description, newValue: newTask.description, actorId: changedBy
            )
        }
        if oldTask.selectedModel != newTask.selectedModel {
            await recordTaskActivity(
                projectID: projectID, taskID: taskID,
                field: .selectedModel,
                oldValue: oldTask.selectedModel,
                newValue: newTask.selectedModel,
                actorId: changedBy
            )
        }
    }

}
