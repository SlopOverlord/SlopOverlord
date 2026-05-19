import Foundation
#if canImport(AppKit)
import AppKit
#endif
import AgentRuntime
import Protocols
import PluginSDK
import Logging

// MARK: - Projects

extension CoreService {
    public struct ProjectChannelLinkConflict: Error {
        public let ownerProjectId: String
        public let ownerProjectName: String
        public let channelId: String
    }

    /// Synthetic `projectId` for `/v1/projects/:id/files/...` when the UI should search the workspace `projects/` directory (all project folders) rather than one project root.
    static let sloppyProjectsDirectoryScopeID = "_sloppyProjectsRoot"

    private static let projectContextBootstrapMarker = "[project_context_bootstrap_v1]"

    private func requiresCompletionConfirmation(changedBy: String) -> Bool {
        let normalized = changedBy.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else {
            return false
        }
        return normalized != "user"
    }

    private func normalizedCompletionNote(_ note: String?) -> String? {
        guard let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }

    public func listProjects() async -> [ProjectRecord] {
        await store.listProjects()
    }

    public func listProjectSummaries() async -> [ProjectListRecord] {
        await store.listProjectSummaries()
    }

    /// Lists token usage records with optional filters and aggregates.
    public func listTokenUsage(
        channelId: String? = nil,
        taskId: String? = nil,
        from: Date? = nil,
        to: Date? = nil
    ) async -> TokenUsageResponse {
        let records = await store.listTokenUsage(channelId: channelId, taskId: taskId, from: from, to: to)
        let totalPrompt = records.reduce(0) { $0 + $1.promptTokens }
        let totalCompletion = records.reduce(0) { $0 + $1.completionTokens }
        let total = records.reduce(0) { $0 + $1.totalTokens }
        return TokenUsageResponse(
            items: records,
            totalPromptTokens: totalPrompt,
            totalCompletionTokens: totalCompletion,
            totalTokens: total
        )
    }

    public func projectAnalytics(projectID: String, query: ProjectAnalyticsQuery) async throws -> ProjectAnalyticsResponse {
        let project = try await getProject(id: projectID)

        let now = Date()
        let rangeFrom: Date?
        let rangeTo: Date?

        switch query.window {
        case .last24h:
            rangeFrom = query.from ?? Calendar.current.date(byAdding: .hour, value: -24, to: now)
            rangeTo = query.to ?? now
        case .last7d:
            rangeFrom = query.from ?? Calendar.current.date(byAdding: .day, value: -7, to: now)
            rangeTo = query.to ?? now
        case .all:
            rangeFrom = query.from
            rangeTo = query.to
        }

        let runtimeCounts = await store.listProjectEventCounts(projectId: project.id, from: rangeFrom, to: rangeTo)

        let outcome = ProjectTaskOutcomeCounts(
            total: project.tasks.count,
            success: project.tasks.filter { $0.status == ProjectTaskStatus.done.rawValue }.count,
            failed: project.tasks.filter { $0.status == ProjectTaskStatus.blocked.rawValue }.count,
            interrupted: project.tasks.filter { $0.status == ProjectTaskStatus.cancelled.rawValue }.count
        )

        let aggregates = await store.listToolInvocationAggregates(projectId: project.id, from: rangeFrom, to: rangeTo)
        let totalCalls = aggregates.reduce(0) { $0 + $1.calls }
        let totalFailures = aggregates.reduce(0) { $0 + $1.failures }
        let totalDuration = aggregates.reduce(0) { $0 + $1.totalDurationMs }
        let avgDurationMs: Int? = totalCalls > 0 ? Int(Double(totalDuration) / Double(totalCalls)) : nil
        let failureRate = totalCalls > 0 ? Double(totalFailures) / Double(totalCalls) : 0

        let durations = await store.listToolInvocationDurations(projectId: project.id, from: rangeFrom, to: rangeTo, limit: 5000).sorted()
        let p50 = percentile(sorted: durations, p: 0.50)
        let p95 = percentile(sorted: durations, p: 0.95)

        let toolAggs: [ProjectToolStats.ToolAggregate] = aggregates.map { agg in
            let avg = agg.calls > 0 ? Int(Double(agg.totalDurationMs) / Double(agg.calls)) : nil
            return .init(tool: agg.tool, calls: agg.calls, failures: agg.failures, avgDurationMs: avg)
        }

        let topByTime = toolAggs
            .sorted { (lhs, rhs) in
                let lhsTotal = (lhs.avgDurationMs ?? 0) * lhs.calls
                let rhsTotal = (rhs.avgDurationMs ?? 0) * rhs.calls
                if lhsTotal != rhsTotal { return lhsTotal > rhsTotal }
                return lhs.tool < rhs.tool
            }
            .prefix(8)

        let topFailing = toolAggs
            .sorted { (lhs, rhs) in
                if lhs.failures != rhs.failures { return lhs.failures > rhs.failures }
                return lhs.tool < rhs.tool
            }
            .prefix(8)

        let toolStats = ProjectToolStats(
            totalCalls: totalCalls,
            totalFailures: totalFailures,
            failureRate: failureRate,
            avgDurationMs: avgDurationMs,
            p50DurationMs: p50,
            p95DurationMs: p95,
            topToolsByTime: Array(topByTime),
            topFailingTools: Array(topFailing)
        )

        let channelIds = project.channels.map { $0.channelId }
        let tokenRecords = await store.listTokenUsage(channelIds: channelIds, from: rangeFrom, to: rangeTo)
        let tokenTotals = ProjectTokenUsageTotals(
            totalPromptTokens: tokenRecords.reduce(0) { $0 + $1.promptTokens },
            totalCompletionTokens: tokenRecords.reduce(0) { $0 + $1.completionTokens },
            totalTokens: tokenRecords.reduce(0) { $0 + $1.totalTokens }
        )

        return ProjectAnalyticsResponse(
            projectId: project.id,
            window: query.window,
            from: rangeFrom,
            to: rangeTo,
            runtimeEventCounts: runtimeCounts,
            taskOutcomes: outcome,
            tools: toolStats,
            tokenUsage: tokenTotals,
            isPartial: false,
            notes: []
        )
    }

    private func percentile(sorted: [Int], p: Double) -> Int? {
        guard !sorted.isEmpty else { return nil }
        let clamped = max(0, min(p, 1))
        let idx = Int(round(clamped * Double(sorted.count - 1)))
        return sorted[min(max(idx, 0), sorted.count - 1)]
    }

    /// Lists runtime event timeline for a channel (newest first) with cursor pagination.
    public func getProject(id: String) async throws -> ProjectRecord {
        guard let normalizedID = normalizedProjectID(id) else {
            throw ProjectError.invalidProjectID
        }
        guard let project = await store.project(id: normalizedID) else {
            throw ProjectError.notFound
        }
        return project
    }

    public func listProjectFiles(projectID: String, path: String) async throws -> [ProjectFileEntry] {
        let rootURL = try await resolveProjectWorkspaceRoot(projectID: projectID)

        let targetURL: URL
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPath.isEmpty || trimmedPath == "/" {
            targetURL = rootURL
        } else {
            targetURL = rootURL.appendingPathComponent(trimmedPath).standardized
        }

        guard isProjectURL(targetURL, inside: rootURL) else {
            throw ProjectError.invalidProjectID
        }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: targetURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw ProjectError.notFound
        }

        let contents = try fm.contentsOfDirectory(at: targetURL, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles])
        var entries: [ProjectFileEntry] = []
        for url in contents {
            let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let isDirectory = resourceValues?.isDirectory ?? false
            let size = resourceValues?.fileSize
            entries.append(ProjectFileEntry(
                name: url.lastPathComponent,
                type: isDirectory ? .directory : .file,
                size: isDirectory ? nil : size
            ))
        }
        entries.sort {
            if $0.type == $1.type { return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return $0.type == .directory
        }
        return entries
    }

    /// Returns project-relative paths whose full path matches the search string (substring, case-insensitive), ranked for autocomplete.
    public func searchProjectFiles(projectID: String, query: String, limit: Int) async throws -> [ProjectFileSearchEntry] {
        let rootURL = try await resolveProjectWorkspaceRoot(projectID: projectID)

        let fm = FileManager.default
        var isRootDir: ObjCBool = false
        guard fm.fileExists(atPath: rootURL.path, isDirectory: &isRootDir), isRootDir.boolValue else {
            throw ProjectError.notFound
        }

        let maxResults = max(1, min(limit, 100))
        let index = ProjectFileIndex.build(projectId: projectID, rootURL: rootURL, limit: ProjectFileIndex.defaultLimit)
        return index.search(query, limit: maxResults).map { entry in
            ProjectFileSearchEntry(path: entry.path, type: entry.type)
        }
    }

    public func readProjectFile(projectID: String, path: String) async throws -> ProjectFileContentResponse {
        let rootURL = try await resolveProjectWorkspaceRoot(projectID: projectID)

        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            throw ProjectError.invalidProjectID
        }

        let targetURL = rootURL.appendingPathComponent(trimmedPath).standardized
        guard isProjectURL(targetURL, inside: rootURL) else {
            throw ProjectError.invalidProjectID
        }

        let maxBytes = 2 * 1024 * 1024
        let data = try Data(contentsOf: targetURL)
        guard data.count <= maxBytes else {
            throw ProjectError.invalidProjectID
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ProjectError.invalidProjectID
        }

        let relativePath = String(targetURL.path.dropFirst(rootURL.path.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return ProjectFileContentResponse(path: relativePath, content: text, sizeBytes: data.count)
    }

    /// Line stats and unified diff for the project workspace (must be a git checkout to return `isGitRepository: true`).
    public func projectWorkingTreeGit(projectID: String) async throws -> ProjectWorkingTreeGitResponse {
        guard let normalizedID = normalizedProjectID(projectID) else {
            throw ProjectError.invalidProjectID
        }
        guard let project = await store.project(id: normalizedID) else {
            throw ProjectError.notFound
        }
        let rootPath = try await resolveProjectWorkspaceRoot(projectID: normalizedID).path
        let provider = sourceControlProvider(for: project)
        let repository = await provider.inspectRepository(at: rootPath)

        guard repository.isRepository else {
            return ProjectWorkingTreeGitResponse(
                isGitRepository: false,
                branch: nil,
                linesAdded: 0,
                linesDeleted: 0,
                diff: "",
                diffTruncated: false,
                message: repository.message ?? "This project folder is not a source-control repository."
            )
        }

        do {
            let status = try await provider.workingTreeStatus(at: rootPath)
            let patch = try await provider.workingTreeDiff(at: rootPath, maxBytes: 512 * 1024)
            return ProjectWorkingTreeGitResponse(
                isGitRepository: true,
                branch: status.repository.branch,
                linesAdded: status.linesAdded,
                linesDeleted: status.linesDeleted,
                diff: patch.text,
                diffTruncated: patch.truncated,
                message: nil
            )
        } catch {
            return ProjectWorkingTreeGitResponse(
                isGitRepository: true,
                branch: nil,
                linesAdded: 0,
                linesDeleted: 0,
                diff: "",
                diffTruncated: false,
                message: error.localizedDescription
            )
        }
    }

    /// Reverts a tracked file under the project workspace to `HEAD` (index + working tree), same as `git restore --source=HEAD --staged --worktree`.
    public func restoreProjectWorkingTreeFile(projectID: String, path: String) async throws {
        guard let normalizedID = normalizedProjectID(projectID) else {
            throw ProjectError.invalidProjectID
        }
        guard let project = await store.project(id: normalizedID) else {
            throw ProjectError.notFound
        }
        let rootURL = try await resolveProjectWorkspaceRoot(projectID: normalizedID)
        let rootPath = rootURL.path
        let provider = sourceControlProvider(for: project)
        let repository = await provider.inspectRepository(at: rootPath)
        guard repository.isRepository else {
            throw ProjectError.invalidPayload
        }

        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProjectError.invalidPayload
        }

        let segments = trimmed.split(separator: "/").map(String.init)
        guard !segments.contains("..") else {
            throw ProjectError.invalidProjectID
        }

        let targetURL = rootURL.appendingPathComponent(trimmed).standardized
        guard isProjectURL(targetURL, inside: rootURL) else {
            throw ProjectError.invalidProjectID
        }

        do {
            try await provider.restorePathFromHead(repoPath: rootPath, relativePath: trimmed)
        } catch {
            throw ProjectError.invalidPayload
        }
    }

    public func refreshProjectContext(projectID: String) async throws -> ProjectContextRefreshResponse {
        await waitForStartup()
        guard let normalizedID = normalizedProjectID(projectID) else {
            throw ProjectError.invalidProjectID
        }
        guard let project = await store.project(id: normalizedID) else {
            throw ProjectError.notFound
        }
        let trimmedRepoPath = project.repoPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedRepoPath.isEmpty else {
            throw ProjectError.invalidPayload
        }

        let resolvedRoot = resolvedProjectRootFromStored(repoPath: project.repoPath, normalizedProjectID: normalizedID)
        let loader = ProjectContextLoader()
        let loaded = loader.load(repoPath: resolvedRoot.path, projectMemoryURL: projectMetaMemoryFileURL(projectID: normalizedID))
        let content = renderProjectContextBootstrap(projectID: normalizedID, projectName: project.name, loaded: loaded)

        let channelIDs = project.channels.map(\.channelId)
        for channelID in channelIDs {
            await runtime.appendSystemMessage(channelId: channelID, content: content)
            await runtime.setChannelBootstrap(channelId: channelID, content: content)
        }

        var loadedDocPaths = loaded.loadedDocs.map(\.relativePath)
        if let loadedProjectMemory = loaded.loadedProjectMemory {
            loadedDocPaths.append(loadedProjectMemory.relativePath)
        }

        return ProjectContextRefreshResponse(
            projectId: normalizedID,
            repoPath: loaded.repoPath,
            appliedChannelIds: channelIDs,
            loadedDocPaths: loadedDocPaths,
            loadedSkillPaths: loaded.loadedSkills.map(\.relativePath),
            totalChars: loaded.totalChars,
            truncated: loaded.truncated
        )
    }

    /// Same markdown as channel `refreshProjectContext`, for merging into agent session bootstrap (no channel writes).
    func projectBootstrapMarkdownForAgentSession(projectID: String) async -> String? {
        await waitForStartup()
        guard let normalizedID = normalizedProjectID(projectID) else {
            return nil
        }
        guard let project = await store.project(id: normalizedID) else {
            return nil
        }
        let trimmedRepoPath = project.repoPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedRepoPath.isEmpty else {
            return nil
        }

        let resolvedRoot = resolvedProjectRootFromStored(repoPath: project.repoPath, normalizedProjectID: normalizedID)
        let loader = ProjectContextLoader()
        let loaded = loader.load(repoPath: resolvedRoot.path, projectMemoryURL: projectMetaMemoryFileURL(projectID: normalizedID))
        return renderProjectContextBootstrap(projectID: normalizedID, projectName: project.name, loaded: loaded)
    }

    private func renderProjectContextBootstrap(
        projectID: String,
        projectName: String,
        loaded: ProjectContextLoader.Result
    ) -> String {
        var lines: [String] = []
        lines.append(Self.projectContextBootstrapMarker)
        lines.append("Project context initialized.")
        lines.append("Project: \(projectName) (\(projectID))")
        lines.append("Repo path: \(loaded.repoPath)")

        if !loaded.loadedDocs.isEmpty {
            lines.append("")
            lines.append("[Project files]")
            for file in loaded.loadedDocs {
                lines.append("")
                lines.append("[\(file.relativePath)]")
                lines.append(file.content)
                if file.truncated {
                    lines.append("")
                    lines.append("(truncated)")
                }
            }
            if let file = loaded.loadedProjectMemory {
                lines.append("")
                lines.append("[\(file.relativePath)]")
                lines.append(file.content)
                if file.truncated {
                    lines.append("")
                    lines.append("(truncated)")
                }
            }
        } else if let file = loaded.loadedProjectMemory {
            lines.append("")
            lines.append("[Project files]")
            lines.append("")
            lines.append("[\(file.relativePath)]")
            lines.append(file.content)
            if file.truncated {
                lines.append("")
                lines.append("(truncated)")
            }
        }

        if !loaded.loadedSkills.isEmpty {
            lines.append("")
            lines.append("[.skills]")
            lines.append("Loaded \(loaded.loadedSkills.count) skill file(s).")
            for file in loaded.loadedSkills {
                lines.append("")
                lines.append("[\(file.relativePath)]")
                lines.append(file.content)
                if file.truncated {
                    lines.append("")
                    lines.append("(truncated)")
                }
            }
        }

        if loaded.truncated {
            lines.append("")
            lines.append("[Note]")
            lines.append("Project context was truncated due to size limits.")
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// Creates a new dashboard project.
    public func createProject(_ request: ProjectCreateRequest) async throws -> ProjectCreateResult {
        let now = Date()
        let normalizedName = try normalizeProjectName(request.name)
        let normalizedDescription = normalizeProjectDescription(request.description)
        let trimmedRepoUrl = request.repoUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasRepoUrl = !trimmedRepoUrl.isEmpty
        let normalizedRepoPath = try normalizedExternalProjectPath(request.repoPath)
        let sourceControlProviderId = normalizedSourceControlProviderID(request.sourceControlProviderId)

        if hasRepoUrl, normalizedRepoPath != nil {
            throw ProjectError.invalidPayload
        }
        let normalizedID: String
        if let requestedID = request.id, !requestedID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let validID = normalizedProjectID(requestedID) else {
                throw ProjectError.invalidProjectID
            }
            guard await store.project(id: validID) == nil else {
                throw ProjectError.conflict
            }
            normalizedID = validID
        } else {
            normalizedID = UUID().uuidString
        }
        let channels = try normalizeInitialProjectChannels(request.channels, fallbackName: normalizedName)
        let project = ProjectRecord(
            id: normalizedID,
            name: normalizedName,
            description: normalizedDescription,
            channels: channels,
            tasks: [],
            actors: request.actors ?? [],
            teams: request.teams ?? [],
            repoPath: normalizedRepoPath,
            sourceControlProviderId: sourceControlProviderId,
            createdAt: now,
            updatedAt: now
        )

        if normalizedRepoPath != nil {
            try prepareExternalProjectWorkspace(projectID: normalizedID)
        }

        await store.saveProject(project)
        let repoCloneSucceeded: Bool?
        if hasRepoUrl {
            repoCloneSucceeded = await cloneProjectRepository(
                repoUrl: trimmedRepoUrl,
                projectID: normalizedID,
                projectDisplayName: normalizedName
            )
        } else {
            ensureProjectWorkspaceDirectory(projectID: normalizedID)
            repoCloneSucceeded = nil
        }
        if !currentConfig.onboarding.completed {
            logger.info(
                "onboarding.project.created",
                metadata: [
                    "project_id": .string(normalizedID),
                    "project_name": .string(normalizedName)
                ]
            )
        }
        return ProjectCreateResult(project: project, repoCloneSucceeded: repoCloneSucceeded)
    }

    public func selectDirectory() async -> String? {
#if canImport(AppKit)
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                NSApplication.shared.activate(ignoringOtherApps: true)

                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                panel.canCreateDirectories = false
                panel.title = "Choose Project Directory"
                panel.prompt = "Open Project"
                panel.level = .floating

                func finish(_ response: NSApplication.ModalResponse) {
                    guard response == .OK else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: panel.url?.path)
                }

                if let window = NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow {
                    panel.beginSheetModal(for: window, completionHandler: finish)
                } else {
                    finish(panel.runModal())
                }
            }
        }
#else
        return nil
#endif
    }

    /// Updates dashboard project metadata.
    public func updateProject(projectID: String, request: ProjectUpdateRequest) async throws -> ProjectRecord {
        guard let normalizedID = normalizedProjectID(projectID) else {
            throw ProjectError.invalidProjectID
        }
        guard var project = await store.project(id: normalizedID) else {
            throw ProjectError.notFound
        }

        if let nextName = request.name {
            project.name = try normalizeProjectName(nextName)
        }
        if let nextDescription = request.description {
            project.description = normalizeProjectDescription(nextDescription)
        }
        if request.icon != nil {
            project.icon = request.icon
        }
        if let nextActors = request.actors {
            project.actors = nextActors
        }
        if let nextTeams = request.teams {
            project.teams = nextTeams
        }
        if let nextModels = request.models {
            project.models = nextModels.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        if let nextAgentFiles = request.agentFiles {
            project.agentFiles = nextAgentFiles.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        if let nextHeartbeat = request.heartbeat {
            project.heartbeat = nextHeartbeat
        }
        if request.repoPath != nil {
            project.repoPath = request.repoPath
        }
        if request.sourceControlProviderId != nil {
            let previousProviderId = project.sourceControlProviderId ?? Self.defaultSourceControlProviderID
            for index in project.tasks.indices where project.tasks[index].worktreeBranch != nil && project.tasks[index].sourceControlProviderId == nil {
                project.tasks[index].sourceControlProviderId = previousProviderId
            }
            project.sourceControlProviderId = normalizedSourceControlProviderID(request.sourceControlProviderId)
        }
        if let nextReviewSettings = request.reviewSettings {
            project.reviewSettings = nextReviewSettings
        }
        if let nextLoopMode = request.taskLoopMode {
            project.taskLoopMode = nextLoopMode
        }
        if let nextFavorite = request.isFavorite {
            project.isFavorite = nextFavorite
        }
        if let nextArchived = request.isArchived {
            project.isArchived = nextArchived
        }

        project.updatedAt = Date()
        await store.saveProject(project)
        await kanbanEventService.push(KanbanEvent(type: .projectUpdated, projectId: normalizedID))
        return project
    }

    /// Deletes one dashboard project and nested board entities.
    /// Cancels all non-terminal tasks before deletion.
    public func deleteProject(projectID: String) async throws {
        guard let normalizedID = normalizedProjectID(projectID) else {
            throw ProjectError.invalidProjectID
        }
        guard var project = await store.project(id: normalizedID) else {
            throw ProjectError.notFound
        }
        for i in project.tasks.indices {
            let status = ProjectTaskStatus(rawValue: project.tasks[i].status)
            if status == nil || !status!.isTerminal {
                project.tasks[i].status = ProjectTaskStatus.cancelled.rawValue
                project.tasks[i].updatedAt = Date()
            }
        }
        project.updatedAt = Date()
        await store.saveProject(project)
        await store.deleteProject(id: normalizedID)
    }

    /// Adds a channel to a dashboard project.
    public func createProjectChannel(
        projectID: String,
        request: ProjectChannelCreateRequest
    ) async throws -> ProjectRecord {
        guard let normalizedID = normalizedProjectID(projectID) else {
            throw ProjectError.invalidProjectID
        }
        guard var project = await store.project(id: normalizedID) else {
            throw ProjectError.notFound
        }

        let title = normalizeChannelTitle(request.title)
        let channelID = try normalizedChannelID(request.channelId)
        if project.channels.contains(where: { $0.channelId == channelID }) {
            throw ProjectError.conflict
        }

        project.channels.append(
            ProjectChannel(
                id: UUID().uuidString,
                title: title,
                channelId: channelID,
                createdAt: Date()
            )
        )
        project.updatedAt = Date()
        await store.saveProject(project)
        return project
    }

    public func linkProjectChannel(
        projectID: String,
        request: ProjectChannelLinkRequest
    ) async throws -> ProjectChannelLinkResponse {
        guard let normalizedID = normalizedProjectID(projectID) else {
            throw ProjectError.invalidProjectID
        }
        guard var project = await store.project(id: normalizedID) else {
            throw ProjectError.notFound
        }

        let channelID = try normalizedChannelID(request.channelId)
        let title = normalizeChannelTitle(request.title ?? channelID)
        let projects = await store.listProjects()
        for candidate in projects where candidate.id != normalizedID {
            if candidate.channels.contains(where: { channelBindingsConflict($0.channelId, channelID) }) {
                throw ProjectChannelLinkConflict(
                    ownerProjectId: candidate.id,
                    ownerProjectName: candidate.name,
                    channelId: channelID
                )
            }
        }

        let status: String
        let channel: ProjectChannel
        if let existing = project.channels.first(where: { channelBindingsConflict($0.channelId, channelID) }) {
            channel = existing
            status = "existing"
        } else {
            channel = ProjectChannel(
                id: UUID().uuidString,
                title: title,
                channelId: channelID,
                createdAt: Date()
            )
            project.channels.append(channel)
            project.updatedAt = Date()
            await store.saveProject(project)
            await kanbanEventService.push(KanbanEvent(type: .projectUpdated, projectId: normalizedID))
            status = "linked"
        }

        let session: ProjectChannelLinkSession?
        if request.ensureSession == true {
            let summary = try await channelSessionStore.ensureOpenSession(channelId: channelID)
            session = ProjectChannelLinkSession(
                channelId: summary.channelId,
                sessionId: summary.sessionId,
                status: summary.status.rawValue
            )
        } else {
            session = nil
        }

        return ProjectChannelLinkResponse(
            project: project,
            channel: channel,
            session: session,
            status: status
        )
    }

    /// Removes a channel from a dashboard project.
    public func deleteProjectChannel(projectID: String, channelID: String) async throws -> ProjectRecord {
        guard let normalizedID = normalizedProjectID(projectID) else {
            throw ProjectError.invalidProjectID
        }
        guard let normalizedChannel = normalizedEntityID(channelID) else {
            throw ProjectError.invalidChannelID
        }
        guard var project = await store.project(id: normalizedID) else {
            throw ProjectError.notFound
        }

        guard project.channels.contains(where: { $0.id == normalizedChannel }) else {
            throw ProjectError.notFound
        }
        if project.channels.count <= 1 {
            throw ProjectError.invalidPayload
        }

        project.channels.removeAll(where: { $0.id == normalizedChannel })
        project.updatedAt = Date()
        await store.saveProject(project)
        return project
    }

    /// Creates a new task inside project board.
    public func createProjectTask(projectID: String, request: ProjectTaskCreateRequest) async throws -> ProjectRecord {
        guard let normalizedID = normalizedProjectID(projectID) else {
            throw ProjectError.invalidProjectID
        }
        guard var project = await store.project(id: normalizedID) else {
            throw ProjectError.notFound
        }

        let now = Date()
        let rawStatus = request.status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let resolvedStatus = ProjectTaskStatus(rawValue: rawStatus) != nil ? rawStatus : ProjectTaskStatus.backlog.rawValue
        let normalizedStatus = try normalizeTaskStatus(resolvedStatus)
        let task = ProjectTask(
            id: nextProjectTaskID(for: project),
            title: try normalizeTaskTitle(request.title),
            description: normalizeTaskDescription(request.description),
            priority: try normalizeTaskPriority(request.priority),
            status: normalizedStatus,
            kind: request.kind,
            loopModeOverride: request.loopModeOverride,
            originType: request.originType,
            originChannelId: request.originChannelId,
            actorId: try normalizeOptionalTaskActorID(request.actorId),
            teamId: try normalizeOptionalTaskTeamID(request.teamId),
            selectedModel: normalizeOptionalTaskSelectedModel(request.selectedModel),
            createdAt: now,
            updatedAt: now
        )
        project.tasks.append(task)
        project.updatedAt = now
        await store.saveProject(project)
        await kanbanEventService.push(KanbanEvent(type: .taskCreated, projectId: normalizedID, task: task))
        await syncOutboundTaskIfNeeded(projectID: normalizedID, taskID: task.id)
        if normalizedStatus == ProjectTaskStatus.ready.rawValue {
            await handleTaskBecameReady(projectID: normalizedID, taskID: task.id)
            if let updated = await store.project(id: normalizedID) {
                return updated
            }
        }
        if let updated = await store.project(id: normalizedID) {
            return updated
        }
        return project
    }

    /// Updates one task inside project board.
    public func updateProjectTask(
        projectID: String,
        taskID: String,
        request: ProjectTaskUpdateRequest
    ) async throws -> ProjectRecord {
        guard let normalizedProject = normalizedProjectID(projectID) else {
            throw ProjectError.invalidProjectID
        }
        guard let normalizedTask = normalizedEntityID(taskID) else {
            throw ProjectError.invalidTaskID
        }
        let normalizedTaskLowercased = normalizedTask.lowercased()
        guard var project = await store.project(id: normalizedProject) else {
            throw ProjectError.notFound
        }
        guard let taskIndex = project.tasks.firstIndex(where: { $0.id.lowercased() == normalizedTaskLowercased }) else {
            throw ProjectError.notFound
        }

        let changedBy = request.changedBy ?? "user"
        let previousStatus = project.tasks[taskIndex].status
        let oldTask = project.tasks[taskIndex]
        var task = oldTask
        let requestedCompletionNote = normalizedCompletionNote(request.completionNote)
        if let status = request.status,
           try normalizeTaskStatus(status) == ProjectTaskStatus.done.rawValue,
           requiresCompletionConfirmation(changedBy: changedBy) {
            guard request.completionConfidence == .done,
                  requestedCompletionNote != nil
            else {
                throw ProjectError.invalidPayload
            }
        }
        if let title = request.title {
            task.title = try normalizeTaskTitle(title)
        }
        if let description = request.description {
            task.description = normalizeTaskDescription(description)
        }
        if let priority = request.priority {
            task.priority = try normalizeTaskPriority(priority)
        }
        if request.actorId != nil {
            task.actorId = try normalizeOptionalTaskActorID(request.actorId)
            task.claimedActorId = nil
            task.claimedAgentId = nil
        }
        if request.teamId != nil {
            task.teamId = try normalizeOptionalTaskTeamID(request.teamId)
            task.claimedActorId = nil
            task.claimedAgentId = nil
        }
        if let kind = request.kind {
            task.kind = kind
        }
        if request.loopModeOverride != nil {
            task.loopModeOverride = request.loopModeOverride
        }
        if request.selectedModel != nil {
            task.selectedModel = normalizeOptionalTaskSelectedModel(request.selectedModel)
        }
        if let tags = request.tags {
            task.tags = normalizeTaskTags(tags)
        }
        if let isArchived = request.isArchived {
            task.isArchived = isArchived
        }
        if let status = request.status {
            task.status = try normalizeTaskStatus(status)
            if task.status == ProjectTaskStatus.backlog.rawValue || task.status == ProjectTaskStatus.cancelled.rawValue {
                task.claimedActorId = nil
                task.claimedAgentId = nil
            }
        }
        let actorChanged = request.actorId != nil && oldTask.actorId != task.actorId
        let teamChanged = request.teamId != nil && oldTask.teamId != task.teamId
        let statusChangedToReady = request.status != nil && task.status == ProjectTaskStatus.ready.rawValue
        let statusChangedToCancelled = request.status != nil && task.status == ProjectTaskStatus.cancelled.rawValue
        if !requiresCompletionConfirmation(changedBy: changedBy),
           actorChanged || teamChanged || statusChangedToReady || statusChangedToCancelled {
            task.routeHistory = []
        }
        task.updatedAt = Date()
        project.tasks[taskIndex] = task
        project.updatedAt = Date()
        await store.saveProject(project)
        await kanbanEventService.push(KanbanEvent(type: .taskUpdated, projectId: normalizedProject, task: task))
        if changedBy != "github" {
            await syncOutboundTaskIfNeeded(projectID: normalizedProject, taskID: task.id)
        }

        await recordTaskFieldChanges(
            projectID: normalizedProject,
            taskID: task.id,
            oldTask: oldTask,
            newTask: task,
            changedBy: changedBy
        )
        if task.status == ProjectTaskStatus.done.rawValue,
           previousStatus != ProjectTaskStatus.done.rawValue,
           let completionNote = requestedCompletionNote {
            appendTaskLifecycleLog(
                projectID: normalizedProject,
                taskID: task.id,
                stage: "completion_confirmed",
                channelID: resolveExecutionChannelID(project: project, task: task),
                workerID: nil,
                message: completionNote,
                actorID: task.claimedActorId,
                agentID: task.claimedAgentId
            )
        }

        let assigneeChangedWhileReady = (actorChanged || teamChanged)
            && task.status == ProjectTaskStatus.ready.rawValue

        if previousStatus != ProjectTaskStatus.ready.rawValue, task.status == ProjectTaskStatus.ready.rawValue {
            await handleTaskBecameReady(projectID: normalizedProject, taskID: task.id)
            if let updated = await store.project(id: normalizedProject) {
                return updated
            }
        } else if assigneeChangedWhileReady {
            await handleTaskBecameReady(projectID: normalizedProject, taskID: task.id)
            if let updated = await store.project(id: normalizedProject) {
                return updated
            }
        }
        return project
    }

    /// Removes one task from project board.
    public func deleteProjectTask(projectID: String, taskID: String) async throws -> ProjectRecord {
        guard let normalizedProject = normalizedProjectID(projectID) else {
            throw ProjectError.invalidProjectID
        }
        guard let normalizedTask = normalizedEntityID(taskID) else {
            throw ProjectError.invalidTaskID
        }
        let normalizedTaskLowercased = normalizedTask.lowercased()
        guard var project = await store.project(id: normalizedProject) else {
            throw ProjectError.notFound
        }
        guard project.tasks.contains(where: { $0.id.lowercased() == normalizedTaskLowercased }) else {
            throw ProjectError.notFound
        }

        project.tasks.removeAll(where: { $0.id.lowercased() == normalizedTaskLowercased })
        project.updatedAt = Date()
        await store.saveProject(project)
        await kanbanEventService.push(KanbanEvent(type: .taskDeleted, projectId: normalizedProject, taskId: normalizedTask))
        return project
    }

    private static let taskArchiveThreshold: TimeInterval = 2 * 24 * 60 * 60

    private static let archivableStatuses: Set<String> = [
        ProjectTaskStatus.done.rawValue,
        ProjectTaskStatus.cancelled.rawValue
    ]

    @discardableResult
    public func archiveOldTasks(projectID: String) async throws -> ProjectRecord {
        guard let normalizedID = normalizedProjectID(projectID) else {
            throw ProjectError.invalidProjectID
        }
        guard var project = await store.project(id: normalizedID) else {
            throw ProjectError.notFound
        }

        let cutoff = Date().addingTimeInterval(-Self.taskArchiveThreshold)
        var changed = false
        for index in project.tasks.indices {
            let task = project.tasks[index]
            if !task.isArchived,
               Self.archivableStatuses.contains(task.status),
               task.updatedAt < cutoff {
                project.tasks[index].isArchived = true
                changed = true
            }
        }

        if changed {
            project.updatedAt = Date()
            await store.saveProject(project)
            await kanbanEventService.push(KanbanEvent(type: .projectUpdated, projectId: normalizedID))
        }
        return project
    }

    public func listArchivedTasks(projectID: String) async throws -> [ProjectTask] {
        let project = try await archiveOldTasks(projectID: projectID)
        return project.tasks.filter(\.isArchived)
    }

    /// Returns one task by readable id (for example, `MOBILE-1`).
    public func getProjectTask(taskReference: String) async throws -> AgentTaskRecord {
        guard let normalizedReference = normalizeTaskReference(taskReference) else {
            throw ProjectError.invalidTaskID
        }
        let normalizedReferenceLowercased = normalizedReference.lowercased()

        let projects = await store.listProjects().sorted(by: { $0.createdAt < $1.createdAt })
        for project in projects {
            guard let task = project.tasks.first(where: { $0.id.lowercased() == normalizedReferenceLowercased }) else {
                continue
            }

            return AgentTaskRecord(
                projectId: project.id,
                projectName: project.name,
                task: task
            )
        }

        throw ProjectError.notFound
    }

    func normalizeProjectName(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 160 else {
            throw ProjectError.invalidPayload
        }
        return trimmed
    }

    func normalizeProjectDescription(_ raw: String?) -> String {
        let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(value.prefix(2_000))
    }

    func normalizeInitialProjectChannels(
        _ channels: [ProjectChannelCreateRequest],
        fallbackName: String
    ) throws -> [ProjectChannel] {
        if channels.isEmpty {
            let slug = slugify(fallbackName)
            return [
                ProjectChannel(
                    id: UUID().uuidString,
                    title: "Main channel",
                    channelId: slug.isEmpty ? "project-main" : "\(slug)-main",
                    createdAt: Date()
                )
            ]
        }

        var normalized: [ProjectChannel] = []
        var uniqueChannelIDs: Set<String> = []
        for channel in channels {
            let title = normalizeChannelTitle(channel.title)
            let channelID = try normalizedChannelID(channel.channelId)
            guard uniqueChannelIDs.insert(channelID).inserted else {
                throw ProjectError.conflict
            }
            normalized.append(
                ProjectChannel(
                    id: UUID().uuidString,
                    title: title,
                    channelId: channelID,
                    createdAt: Date()
                )
            )
        }
        return normalized
    }

    func normalizeTaskTitle(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProjectError.invalidPayload
        }
        return String(trimmed.prefix(240))
    }

    func normalizeTaskDescription(_ raw: String?) -> String {
        let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(value.prefix(8_000))
    }

    func normalizeTaskPriority(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed = Set(["low", "medium", "high"])
        guard allowed.contains(value) else {
            throw ProjectError.invalidPayload
        }
        return value
    }

    func normalizeTaskStatus(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed = Set(ProjectTaskStatus.allCases.map(\.rawValue))
        guard allowed.contains(value) else {
            throw ProjectError.invalidPayload
        }
        return value
    }

    func normalizeOptionalTaskActorID(_ raw: String?) throws -> String? {
        guard let raw else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        guard let normalized = normalizedActorEntityID(trimmed) else {
            throw ProjectError.invalidPayload
        }
        return normalized
    }

    func normalizeOptionalTaskTeamID(_ raw: String?) throws -> String? {
        guard let raw else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        guard let normalized = normalizedActorEntityID(trimmed) else {
            throw ProjectError.invalidPayload
        }
        return normalized
    }

    func normalizeOptionalTaskSelectedModel(_ raw: String?) -> String? {
        guard let raw else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func normalizeTaskReference(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let token = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        return normalizedEntityID(token)
    }

    func nextProjectTaskID(for project: ProjectRecord) -> String {
        let prefix = projectTaskIDPrefix(for: project)
        let taskPrefix = "\(prefix)-"
        let maxSequence = project.tasks.reduce(0) { partial, task in
            max(partial, taskSequenceNumber(taskID: task.id, prefix: taskPrefix) ?? 0)
        }
        return "\(prefix)-\(maxSequence + 1)"
    }

    func projectTaskIDPrefix(for project: ProjectRecord) -> String {
        var candidates: [String] = []
        if !isLikelyUUID(project.id) {
            candidates.append(project.id)
        }
        candidates.append(project.name)
        if isLikelyUUID(project.id) {
            candidates.append(project.id)
        }

        for candidate in candidates {
            let normalized = normalizeTaskPrefix(candidate)
            if !normalized.isEmpty {
                return normalized
            }
        }

        return "PROJECT"
    }

    func taskSequenceNumber(taskID: String, prefix: String) -> Int? {
        let uppercased = taskID.uppercased()
        guard uppercased.hasPrefix(prefix) else {
            return nil
        }

        let suffix = String(uppercased.dropFirst(prefix.count))
        guard !suffix.isEmpty,
              suffix.rangeOfCharacter(from: CharacterSet.decimalDigits.inverted) == nil
        else {
            return nil
        }
        return Int(suffix)
    }

    func normalizeTaskPrefix(_ raw: String) -> String {
        let uppercased = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard !uppercased.isEmpty else {
            return ""
        }

        let compacted = uppercased.replacingOccurrences(
            of: #"[^A-Z0-9]+"#,
            with: "-",
            options: .regularExpression
        )
        let trimmed = compacted.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(trimmed.prefix(80))
    }

    func isLikelyUUID(_ raw: String) -> Bool {
        raw.range(
            of: #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#,
            options: .regularExpression
        ) != nil
    }

    func jsonValue(for task: ProjectTask) -> JSONValue {
        .object([
            "id": .string(task.id),
            "title": .string(task.title),
            "description": .string(task.description),
            "priority": .string(task.priority),
            "status": .string(task.status),
            "actorId": task.actorId.map { .string($0) } ?? .null,
            "teamId": task.teamId.map { .string($0) } ?? .null,
            "claimedActorId": task.claimedActorId.map { .string($0) } ?? .null,
            "claimedAgentId": task.claimedAgentId.map { .string($0) } ?? .null,
            "swarmId": task.swarmId.map { .string($0) } ?? .null,
            "swarmTaskId": task.swarmTaskId.map { .string($0) } ?? .null,
            "swarmParentTaskId": task.swarmParentTaskId.map { .string($0) } ?? .null,
            "swarmDependencyIds": task.swarmDependencyIds.map { .array($0.map { .string($0) }) } ?? .null,
            "swarmDepth": task.swarmDepth.map { .number(Double($0)) } ?? .null,
            "swarmActorPath": task.swarmActorPath.map { .array($0.map { .string($0) }) } ?? .null,
            "selectedModel": task.selectedModel.map { .string($0) } ?? .null,
            "createdAt": .string(ISO8601DateFormatter().string(from: task.createdAt)),
            "updatedAt": .string(ISO8601DateFormatter().string(from: task.updatedAt))
        ])
    }

    func normalizeChannelTitle(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Channel"
        }
        return String(trimmed.prefix(160))
    }

    func normalizeTaskTags(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var tags: [String] = []
        for value in raw {
            let tag = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
            guard !tag.isEmpty else {
                continue
            }
            let key = tag.lowercased()
            guard !seen.contains(key) else {
                continue
            }
            seen.insert(key)
            tags.append(tag)
            if tags.count >= 24 {
                break
            }
        }
        return tags
    }

    func normalizedProjectID(_ raw: String) -> String? {
        normalizedEntityID(raw)
    }

    func normalizedSourceControlProviderID(_ raw: String?) -> String? {
        guard let raw else {
            return nil
        }
        return normalizedEntityID(raw)
    }

    func normalizedEntityID(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard trimmed.rangeOfCharacter(from: allowed.inverted) == nil, trimmed.count <= 180 else {
            return nil
        }

        return trimmed
    }

    func normalizedChannelID(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.:/")
            .union(CharacterSet(charactersIn: "\u{001E}"))
        guard !trimmed.isEmpty, trimmed.count <= 200, trimmed.rangeOfCharacter(from: allowed.inverted) == nil else {
            throw ProjectError.invalidChannelID
        }
        return trimmed
    }

    func channelBindingsConflict(_ left: String, _ right: String) -> Bool {
        let lhs = left.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhs = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lhs.isEmpty, !rhs.isEmpty else {
            return false
        }
        return lhs == rhs
    }

    func slugify(_ raw: String) -> String {
        let lower = raw.lowercased()
        let separated = lower.replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        return separated.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    func projectDirectoryURL(projectID: String) -> URL {
        workspaceRootURL
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(projectID, isDirectory: true)
    }

    /// Resolves persisted `repoPath` to a workspace directory URL.
    /// Paths like `/projects/<id>` are stored as if absolute but are intended relative to the Sloppy workspace root.
    private func resolvedProjectRootFromStored(repoPath: String?, normalizedProjectID: String) -> URL {
        guard let raw = repoPath?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return projectDirectoryURL(projectID: normalizedProjectID).standardized
        }
        let direct = URL(fileURLWithPath: raw, isDirectory: true).standardized
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: direct.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return direct
        }
        if raw.hasPrefix("/projects/") || raw.hasPrefix("projects/") {
            let relative = raw.hasPrefix("/") ? String(raw.dropFirst()) : raw
            let segments = relative.split(separator: "/").map(String.init)
            if !segments.isEmpty {
                let candidate = segments.reduce(workspaceRootURL) { base, segment in
                    base.appendingPathComponent(segment, isDirectory: true)
                }.standardized
                isDirectory = false
                if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    return candidate
                }
            }
            return projectDirectoryURL(projectID: normalizedProjectID).standardized
        }
        return direct
    }

    func resolveProjectWorkspaceRoot(projectID: String) async throws -> URL {
        guard let normalizedID = normalizedProjectID(projectID) else {
            throw ProjectError.invalidProjectID
        }

        if normalizedID == Self.sloppyProjectsDirectoryScopeID {
            let projectsRootURL = workspaceRootURL.appendingPathComponent("projects", isDirectory: true).standardized
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: projectsRootURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ProjectError.notFound
            }
            return projectsRootURL
        }

        if let project = await store.project(id: normalizedID) {
            return resolvedProjectRootFromStored(repoPath: project.repoPath, normalizedProjectID: normalizedID)
        }

        let diskProjectURL = projectDirectoryURL(projectID: normalizedID).standardized
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: diskProjectURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw ProjectError.notFound
        }
        return diskProjectURL
    }

    func isProjectURL(_ url: URL, inside rootURL: URL) -> Bool {
        let rootPath = rootURL.standardizedFileURL.path
        let targetPath = url.standardizedFileURL.path
        return targetPath == rootPath || targetPath.hasPrefix(rootPath + "/")
    }

    func projectMetaDirectoryURL(projectID: String) -> URL {
        projectDirectoryURL(projectID: projectID).appendingPathComponent(".meta", isDirectory: true)
    }

    func projectMetaMemoryFileURL(projectID: String) -> URL {
        projectMetaDirectoryURL(projectID: projectID).appendingPathComponent("MEMORY.md", isDirectory: false)
    }

    func projectTaskLogFileURL(projectID: String, taskID: String) -> URL {
        projectMetaDirectoryURL(projectID: projectID).appendingPathComponent("task-\(taskID).log")
    }

    func relativePathFromWorkspace(_ url: URL) -> String {
        let workspacePath = workspaceRootURL.path
        let targetPath = url.path
        if targetPath.hasPrefix(workspacePath) {
            let suffix = targetPath.dropFirst(workspacePath.count)
            return suffix.hasPrefix("/") ? String(suffix.dropFirst()) : String(suffix)
        }
        return targetPath
    }

}
