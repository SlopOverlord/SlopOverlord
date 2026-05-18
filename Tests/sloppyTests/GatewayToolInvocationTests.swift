import Foundation
import Testing
@testable import sloppy
@testable import Protocols

@Suite("Gateway channel tool invocation")
struct GatewayToolInvocationTests {
    private func makeService() -> CoreService {
        CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
    }

    private func makeAgent(service: CoreService, agentID: String) async throws {
        _ = try await service.createAgent(
            AgentCreateRequest(id: agentID, displayName: "Gateway Agent", role: "Gateway tool tests")
        )
    }

    @Test("gateway channel tool calls honor linked agent tool policy")
    func gatewayChannelToolCallsHonorAgentPolicy() async throws {
        let service = makeService()
        let agentID = "gateway-tools-\(UUID().uuidString)"
        try await makeAgent(service: service, agentID: agentID)

        _ = try await service.updateAgentToolsPolicy(
            agentID: agentID,
            request: AgentToolsUpdateRequest(
                defaultPolicy: .deny,
                tools: [:],
                guardrails: AgentToolsGuardrails()
            )
        )

        let result = await service.invokeToolFromChannelRuntime(
            agentID: agentID,
            channelID: "channel:telegram",
            request: ToolInvocationRequest(
                tool: "files.read",
                arguments: ["path": .string("README.md")]
            )
        )

        #expect(result.ok == false)
        #expect(result.error?.code == "tool_forbidden")
    }

    @Test("gateway channel tool calls resolve relative paths from linked project root")
    func gatewayChannelToolCallsResolveRelativePathsFromProjectRoot() async throws {
        let service = makeService()
        let agentID = "gateway-project-\(UUID().uuidString)"
        try await makeAgent(service: service, agentID: agentID)

        let repoRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("gateway-project-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        let noteURL = repoRoot.appendingPathComponent("note.txt")
        try Data("hello from gateway".utf8).write(to: noteURL)

        let projectID = "gateway-project-\(UUID().uuidString)"
        let channelID = "channel:telegram:\(UUID().uuidString)"

        _ = try await service.createProject(
            ProjectCreateRequest(
                id: projectID,
                name: "Gateway Project",
                channels: [.init(title: "Telegram", channelId: channelID)],
                repoPath: repoRoot.path
            )
        )

        let result = await service.invokeToolFromChannelRuntime(
            agentID: agentID,
            channelID: channelID,
            request: ToolInvocationRequest(
                tool: "files.read",
                arguments: ["path": .string("note.txt")]
            )
        )

        #expect(result.ok == true)
        guard case .object(let payload)? = result.data else {
            Issue.record("Expected object payload from files.read")
            return
        }
        #expect(payload["path"]?.asString == noteURL.path)
        #expect(payload["content"]?.asString == "hello from gateway")
    }

    @Test("gateway project tools treat empty optional ids as current channel")
    func gatewayProjectToolsTreatEmptyOptionalIdsAsCurrentChannel() async throws {
        let service = makeService()
        let agentID = "gateway-project-empty-args-\(UUID().uuidString)"
        let projectID = "gateway-empty-args-\(UUID().uuidString)"
        let channelID = "telegram-agent-\(UUID().uuidString)\u{001E}tgthread:42"
        try await makeAgent(service: service, agentID: agentID)

        _ = try await service.createProject(
            ProjectCreateRequest(
                id: projectID,
                name: "Gateway Empty Args",
                channels: [.init(title: "Telegram topic", channelId: channelID)]
            )
        )
        _ = try await service.createProjectTask(
            projectID: projectID,
            request: ProjectTaskCreateRequest(title: "Existing task", status: ProjectTaskStatus.backlog.rawValue)
        )

        let emptyOptionalArguments: [String: JSONValue] = [
            "channelId": .string(""),
            "projectId": .string(""),
            "status": .string(""),
            "topicId": .string("")
        ]
        let listResult = await service.invokeToolFromChannelRuntime(
            agentID: agentID,
            channelID: channelID,
            request: ToolInvocationRequest(
                tool: "project.task_list",
                arguments: emptyOptionalArguments
            )
        )

        #expect(listResult.ok == true)
        #expect(listResult.data?.asObject?["projectId"]?.asString == projectID)
        #expect(listResult.data?.asObject?["tasks"]?.asArray?.count == 1)

        let createResult = await service.invokeToolFromChannelRuntime(
            agentID: agentID,
            channelID: channelID,
            request: ToolInvocationRequest(
                tool: "project.task_create",
                arguments: emptyOptionalArguments.merging([
                    "title": .string("New task"),
                    "description": .string(planningTaskBrief())
                ]) { _, new in new }
            )
        )

        #expect(createResult.ok == true)
        #expect(createResult.data?.asObject?["projectId"]?.asString == projectID)
        #expect(createResult.data?.asObject?["status"]?.asString == ProjectTaskStatus.pendingApproval.rawValue)
    }

    @Test("gateway planning task create rejects sparse descriptions")
    func gatewayPlanningTaskCreateRejectsSparseDescriptions() async throws {
        let service = makeService()
        let agentID = "gateway-task-brief-reject-\(UUID().uuidString)"
        let projectID = "gateway-task-brief-reject-\(UUID().uuidString)"
        let channelID = "channel:brief-reject-\(UUID().uuidString)"
        try await makeAgent(service: service, agentID: agentID)

        _ = try await service.createProject(
            ProjectCreateRequest(
                id: projectID,
                name: "Task Brief Reject",
                channels: [.init(title: "Brief Reject", channelId: channelID)]
            )
        )

        let result = await service.invokeToolFromChannelRuntime(
            agentID: agentID,
            channelID: channelID,
            request: ToolInvocationRequest(
                tool: "project.task_create",
                arguments: [
                    "projectId": .string(projectID),
                    "title": .string("Fix screenshot tests")
                ]
            ),
            chatMode: .plan
        )

        #expect(result.ok == false)
        #expect(result.error?.code == "task_brief_required")
        #expect(result.error?.retryable == true)
        #expect(result.error?.hint?.contains("## Goal") == true)
        #expect(result.error?.hint?.contains("full planning handoff") == true)
    }

    @Test("gateway planning task create accepts full task brief")
    func gatewayPlanningTaskCreateAcceptsFullTaskBrief() async throws {
        let service = makeService()
        let agentID = "gateway-task-brief-accept-\(UUID().uuidString)"
        let projectID = "gateway-task-brief-accept-\(UUID().uuidString)"
        let channelID = "channel:brief-accept-\(UUID().uuidString)"
        try await makeAgent(service: service, agentID: agentID)

        _ = try await service.createProject(
            ProjectCreateRequest(
                id: projectID,
                name: "Task Brief Accept",
                channels: [.init(title: "Brief Accept", channelId: channelID)]
            )
        )

        let result = await service.invokeToolFromChannelRuntime(
            agentID: agentID,
            channelID: channelID,
            request: ToolInvocationRequest(
                tool: "project.task_create",
                arguments: [
                    "projectId": .string(projectID),
                    "title": .string("Fix screenshot tests"),
                    "description": .string(planningTaskBrief()),
                    "kind": .string(ProjectTaskKind.planning.rawValue),
                    "status": .string(ProjectTaskStatus.pendingApproval.rawValue)
                ]
            ),
            chatMode: .plan
        )

        #expect(result.ok == true)
        let project = try await service.getProject(id: projectID)
        let task = try #require(project.tasks.first(where: { $0.title == "Fix screenshot tests" }))
        #expect(task.description.contains("Example/YX360Promozavr_ScreenshotMaker"))
        #expect(task.description.contains("Potential risks from planning"))
    }

    @Test("core API still accepts short manual task descriptions")
    func coreAPIStillAcceptsShortManualTaskDescriptions() async throws {
        let service = makeService()
        let projectID = "gateway-core-short-task-\(UUID().uuidString)"

        _ = try await service.createProject(
            ProjectCreateRequest(id: projectID, name: "Core Short Task")
        )

        let project = try await service.createProjectTask(
            projectID: projectID,
            request: ProjectTaskCreateRequest(
                title: "Manual short task",
                description: "Small manual note",
                status: ProjectTaskStatus.pendingApproval.rawValue
            )
        )

        let task = try #require(project.tasks.first(where: { $0.title == "Manual short task" }))
        #expect(task.description == "Small manual note")
        #expect(task.status == ProjectTaskStatus.pendingApproval.rawValue)
    }

    @Test("gateway plan input tool records pending request and option answer")
    func gatewayPlanInputRecordsPendingRequestAndOptionAnswer() async throws {
        let service = makeService()
        let agentID = "gateway-plan-input-\(UUID().uuidString)"
        let channelID = "channel:telegram"
        try await makeAgent(service: service, agentID: agentID)

        let result = await service.invokeToolFromChannelRuntime(
            agentID: agentID,
            channelID: channelID,
            request: ToolInvocationRequest(
                tool: "planning.request_input",
                arguments: [
                    "title": .string("Choose direction"),
                    "questions": .array([
                        .object([
                            "id": .string("direction"),
                            "question": .string("Which path should I take?"),
                            "options": .array([
                                .object(["id": .string("small"), "label": .string("Small")]),
                                .object(["id": .string("large"), "label": .string("Large")])
                            ])
                        ])
                    ])
                ]
            ),
            chatMode: .plan
        )

        #expect(result.ok == true)
        let requestID = try #require(result.data?.asObject?["requestId"]?.asString)
        let pending = try await service.channelSessionStore.pendingInputRequest(channelId: channelID)
        #expect(pending?.request.id == requestID)

        let answered = await service.answerChannelPlanInputOption(
            channelId: channelID,
            userId: "tg:1",
            requestId: requestID,
            questionId: "direction",
            optionId: "small",
            topicId: nil
        )

        #expect(answered == true)
        let sessionID = try #require(pending?.sessionId)
        let detail = try await service.channelSessionStore.loadSessionDetail(sessionID: sessionID)
        #expect(detail.events.contains { $0.type == .inputResponse && $0.inputResponse?.requestId == requestID })
    }

    @Test("agent debug input tool records pending request")
    func agentDebugInputRecordsPendingRequest() async throws {
        let service = makeService()
        let agentID = "agent-debug-input-\(UUID().uuidString)"
        try await makeAgent(service: service, agentID: agentID)
        let session = try await service.createAgentSession(
            agentID: agentID,
            request: AgentSessionCreateRequest(title: "Debug verdict")
        )

        let result = await service.invokeToolFromRuntime(
            agentID: agentID,
            sessionID: session.id,
            request: ToolInvocationRequest(
                tool: "planning.request_input",
                arguments: [
                    "title": .string("Verify debug result"),
                    "questions": .array([
                        .object([
                            "id": .string("debug_verdict"),
                            "question": .string("What happened after testing the instrumented build?"),
                            "options": .array([
                                .object(["id": .string("mark_as_fixed"), "label": .string("Mark as fixed")]),
                                .object(["id": .string("bug_repeated"), "label": .string("Bug is repeated")])
                            ]),
                            "allowCustomAnswer": .bool(false)
                        ])
                    ])
                ]
            ),
            chatMode: .debug
        )

        #expect(result.ok == true)
        let requestID = try #require(result.data?.asObject?["requestId"]?.asString)
        let detail = try await service.getAgentSession(agentID: agentID, sessionID: session.id)
        let inputRequest = try #require(detail.events.compactMap(\.inputRequest).last)
        #expect(inputRequest.id == requestID)
        #expect(inputRequest.mode == AgentChatMode.debug.rawValue)
        #expect(inputRequest.questions.first?.options.map(\.id) == ["mark_as_fixed", "bug_repeated"])
    }

    @Test("agent build progress rejects empty items")
    func agentBuildProgressRejectsEmptyItems() async throws {
        let service = makeService()
        let agentID = "agent-build-progress-empty-\(UUID().uuidString)"
        try await makeAgent(service: service, agentID: agentID)
        let session = try await service.createAgentSession(
            agentID: agentID,
            request: AgentSessionCreateRequest(title: "Build progress")
        )

        let result = await service.invokeToolFromRuntime(
            agentID: agentID,
            sessionID: session.id,
            request: ToolInvocationRequest(
                tool: "planning.progress_update",
                arguments: ["items": .array([])]
            ),
            chatMode: .build
        )

        #expect(result.ok == false)
        #expect(result.error?.code == "invalid_arguments")
    }

    @Test("agent build progress rejects duplicate item ids")
    func agentBuildProgressRejectsDuplicateItemIDs() async throws {
        let service = makeService()
        let agentID = "agent-build-progress-duplicate-\(UUID().uuidString)"
        try await makeAgent(service: service, agentID: agentID)
        let session = try await service.createAgentSession(
            agentID: agentID,
            request: AgentSessionCreateRequest(title: "Build progress")
        )

        let result = await service.invokeToolFromRuntime(
            agentID: agentID,
            sessionID: session.id,
            request: ToolInvocationRequest(
                tool: "planning.progress_update",
                arguments: [
                    "items": .array([
                        buildProgressItem(id: "same", title: "First", status: "pending"),
                        buildProgressItem(id: "same", title: "Second", status: "pending")
                    ])
                ]
            ),
            chatMode: .build
        )

        #expect(result.ok == false)
        #expect(result.error?.code == "invalid_arguments")
        #expect(result.error?.message.contains("Duplicate") == true)
    }

    @Test("agent build progress rejects unknown statuses")
    func agentBuildProgressRejectsUnknownStatuses() async throws {
        let service = makeService()
        let agentID = "agent-build-progress-status-\(UUID().uuidString)"
        try await makeAgent(service: service, agentID: agentID)
        let session = try await service.createAgentSession(
            agentID: agentID,
            request: AgentSessionCreateRequest(title: "Build progress")
        )

        let result = await service.invokeToolFromRuntime(
            agentID: agentID,
            sessionID: session.id,
            request: ToolInvocationRequest(
                tool: "planning.progress_update",
                arguments: [
                    "items": .array([
                        buildProgressItem(id: "bad", title: "Bad", status: "almost_done")
                    ])
                ]
            ),
            chatMode: .build
        )

        #expect(result.ok == false)
        #expect(result.error?.code == "invalid_arguments")
        #expect(result.error?.message.contains("unknown") == true)
    }

    @Test("agent build progress records session event")
    func agentBuildProgressRecordsSessionEvent() async throws {
        let service = makeService()
        let agentID = "agent-build-progress-valid-\(UUID().uuidString)"
        try await makeAgent(service: service, agentID: agentID)
        let session = try await service.createAgentSession(
            agentID: agentID,
            request: AgentSessionCreateRequest(title: "Build progress")
        )

        let result = await service.invokeToolFromRuntime(
            agentID: agentID,
            sessionID: session.id,
            request: ToolInvocationRequest(
                tool: "planning.progress_update",
                arguments: [
                    "title": .string("Progress"),
                    "items": .array([
                        buildProgressItem(id: "plan", title: "Plan", status: "done"),
                        buildProgressItem(id: "verify", title: "Verify", status: "in_progress", details: "Running checks")
                    ])
                ]
            ),
            chatMode: .build
        )

        #expect(result.ok == true)
        #expect(result.data?.asObject?["progress"]?.asObject?["title"]?.asString == "Progress")
        let detail = try await service.getAgentSession(agentID: agentID, sessionID: session.id)
        let progress = try #require(detail.events.compactMap(\.buildProgress).last)
        #expect(progress.items.map(\.id) == ["plan", "verify"])
        #expect(progress.items.last?.status == .inProgress)
        #expect(progress.items.last?.details == "Running checks")
    }

    @Test("gateway input tool rejects outside plan or debug mode")
    func gatewayInputRejectsOutsidePlanOrDebugMode() async throws {
        let service = makeService()
        let agentID = "gateway-plan-input-reject-\(UUID().uuidString)"
        try await makeAgent(service: service, agentID: agentID)

        let result = await service.invokeToolFromChannelRuntime(
            agentID: agentID,
            channelID: "channel:telegram",
            request: ToolInvocationRequest(
                tool: "planning.request_input",
                arguments: [
                    "questions": .array([
                        .object([
                            "id": .string("direction"),
                            "question": .string("Which path?"),
                            "options": .array([
                                .object(["id": .string("small"), "label": .string("Small")]),
                                .object(["id": .string("large"), "label": .string("Large")])
                            ])
                        ])
                    ])
                ]
            ),
            chatMode: .ask
        )

        #expect(result.ok == false)
        #expect(result.error?.code == "input_mode_required")
    }

    private func buildProgressItem(
        id: String,
        title: String,
        status: String,
        details: String? = nil
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(id),
            "title": .string(title),
            "status": .string(status),
            "definitionOfDone": .string("Done when \(title.lowercased()) is complete")
        ]
        if let details {
            object["details"] = .string(details)
        }
        return .object(object)
    }

    private func planningTaskBrief() -> String {
        """
        ## Goal
        Fix the screenshot tests so `make_snapshots` produces screenshots for every language and theme.

        ## Context
        Planning found key files in `Example/YX360Promozavr_ScreenshotMaker`, including the main screenshot maker, snapshot helper, parameters, Fastfile, and Xcode scheme. Potential risks from planning include async `@MainActor` UI test hangs, launch environment values not being read by the sample app, setupSnapshot ordering, external plugin availability, AccountManagerHolder token setup, and Xcode scheme compatibility.

        ## Definition of Done
        The screenshot lane succeeds for all configured languages and themes, and the task preserves the planning findings for Build mode.

        ## Tests / Verification
        Run `bundle exec fastlane make_snapshots` or the repository-equivalent screenshot lane, then verify generated artifacts for all expected configurations.
        """
    }
}
