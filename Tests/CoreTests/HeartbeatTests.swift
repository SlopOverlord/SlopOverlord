import Foundation
import Logging
import Testing
@testable import Core
@testable import PluginSDK
@testable import Protocols

private actor FixedHeartbeatModelProvider: ModelProviderPlugin {
    nonisolated let id: String = "heartbeat-fixed-provider"
    nonisolated let models: [String]

    private let responseText: String

    init(models: [String] = ["openai:gpt-4.1-mini"], responseText: String) {
        self.models = models
        self.responseText = responseText
    }

    func complete(
        model: String,
        prompt: String,
        maxTokens: Int,
        reasoningEffort: ReasoningEffort?
    ) async throws -> String {
        responseText
    }
}

private func makeHeartbeatService() -> (CoreService, CoreConfig) {
    let workspaceName = "workspace-heartbeat-\(UUID().uuidString)"
    let sqlitePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("core-heartbeat-\(UUID().uuidString).sqlite")
        .path

    var config = CoreConfig.default
    config.workspace = .init(name: workspaceName, basePath: FileManager.default.temporaryDirectory.path)
    config.sqlitePath = sqlitePath
    return (CoreService(config: config), config)
}

@discardableResult
private func configureHeartbeatAgent(
    service: CoreService,
    agentID: String,
    heartbeatMarkdown: String,
    enabled: Bool = true,
    intervalMinutes: Int = 1
) async throws -> AgentConfigDetail {
    _ = try await service.createAgent(
        AgentCreateRequest(
            id: agentID,
            displayName: "Heartbeat \(agentID)",
            role: "Heartbeat test agent"
        )
    )

    let current = try await service.getAgentConfig(agentID: agentID)
    var documents = current.documents
    documents.heartbeatMarkdown = heartbeatMarkdown

    return try await service.updateAgentConfig(
        agentID: agentID,
        request: AgentConfigUpdateRequest(
            selectedModel: current.selectedModel,
            documents: documents,
            heartbeat: AgentHeartbeatSettings(
                enabled: enabled,
                intervalMinutes: intervalMinutes
            )
        )
    )
}

@Test
func emptyHeartbeatMarksSuccessWithoutCreatingSession() async throws {
    let (service, _) = makeHeartbeatService()
    try await configureHeartbeatAgent(
        service: service,
        agentID: "heartbeat-empty",
        heartbeatMarkdown: ""
    )

    await service.runAgentHeartbeat(agentID: "heartbeat-empty")

    let config = try await service.getAgentConfig(agentID: "heartbeat-empty")
    let sessions = try await service.listAgentSessions(agentID: "heartbeat-empty")

    #expect(config.heartbeatStatus.lastResult == "ok_empty")
    #expect(config.heartbeatStatus.lastSuccessAt != nil)
    #expect(config.heartbeatStatus.lastSessionId == nil)
    #expect(sessions.isEmpty)
}

@Test
func successfulHeartbeatCreatesHiddenSession() async throws {
    let (service, _) = makeHeartbeatService()
    await service.overrideModelProviderForTests(
        FixedHeartbeatModelProvider(responseText: "SLOPPY_ACTION_OK"),
        defaultModel: "openai:gpt-4.1-mini"
    )
    try await configureHeartbeatAgent(
        service: service,
        agentID: "heartbeat-success",
        heartbeatMarkdown: "- verify project health\n"
    )

    await service.runAgentHeartbeat(agentID: "heartbeat-success")

    let config = try await service.getAgentConfig(agentID: "heartbeat-success")
    let sessions = try await service.listAgentSessions(agentID: "heartbeat-success")
    let heartbeatSessionID = try #require(config.heartbeatStatus.lastSessionId)
    let sessionDetail = try await service.getAgentSession(agentID: "heartbeat-success", sessionID: heartbeatSessionID)

    #expect(config.heartbeatStatus.lastResult == "ok")
    #expect(config.heartbeatStatus.lastErrorMessage == nil)
    #expect(sessions.isEmpty)
    #expect(sessionDetail.summary.kind == .heartbeat)
    #expect(sessionDetail.events.contains(where: {
        $0.type == .message && $0.message?.role == .assistant
    }))
}

@Test
func failedHeartbeatStoresErrorAndNotifiesDefaultAgentChannel() async throws {
    let (service, _) = makeHeartbeatService()
    await service.overrideModelProviderForTests(
        FixedHeartbeatModelProvider(responseText: "Deployment drift detected"),
        defaultModel: "openai:gpt-4.1-mini"
    )
    try await configureHeartbeatAgent(
        service: service,
        agentID: "heartbeat-failure",
        heartbeatMarkdown: "- verify deployment parity\n"
    )

    await service.runAgentHeartbeat(agentID: "heartbeat-failure")

    let config = try await service.getAgentConfig(agentID: "heartbeat-failure")
    let channelState = await service.getChannelState(channelId: "agent:heartbeat-failure")
    let messages = channelState?.messages.map(\.content) ?? []

    #expect(config.heartbeatStatus.lastResult == "failed")
    #expect(config.heartbeatStatus.lastFailureAt != nil)
    #expect(config.heartbeatStatus.lastErrorMessage?.contains("Deployment drift detected") == true)
    #expect(messages.contains(where: { $0.contains("HEARTBEAT failed for agent heartbeat-failure") }))
}

@Test
func heartbeatRunnerLifecycleAndManualTrigger() async throws {
    let (service, _) = makeHeartbeatService()
    await service.overrideModelProviderForTests(
        FixedHeartbeatModelProvider(responseText: "SLOPPY_ACTION_OK"),
        defaultModel: "openai:gpt-4.1-mini"
    )
    try await configureHeartbeatAgent(
        service: service,
        agentID: "heartbeat-runner",
        heartbeatMarkdown: "- verify runner delivery\n"
    )

    #expect(await service.heartbeatRunnerRunningForTests() == false)
    await service.bootstrapChannelPlugins()
    #expect(await service.heartbeatRunnerRunningForTests() == true)

    await service.shutdownChannelPlugins()
    #expect(await service.heartbeatRunnerRunningForTests() == false)
}

@Test
func heartbeatRunnerPreventsOverlappingAgentRuns() async throws {
    actor State {
        var isRunning = false
        var overlapCount = 0
        var completedRuns = 0

        func enter() -> Bool {
            if isRunning {
                overlapCount += 1
                return false
            }
            isRunning = true
            return true
        }

        func leave() {
            isRunning = false
            completedRuns += 1
        }

        func snapshot() -> (Int, Int) {
            (overlapCount, completedRuns)
        }
    }

    let state = State()
    let runner = HeartbeatRunner(
        logger: Logger(label: "test.heartbeat.runner"),
        scheduleProvider: {
            [AgentHeartbeatSchedule(agentId: "overlap-agent", intervalMinutes: 1, lastRunAt: nil)]
        },
        executor: { _ in
            guard await state.enter() else {
                return
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
            await state.leave()
        }
    )

    async let firstTrigger: Void = runner.triggerImmediately()
    async let secondTrigger: Void = runner.triggerImmediately()
    _ = await (firstTrigger, secondTrigger)
    try? await Task.sleep(nanoseconds: 300_000_000)

    let snapshot = await state.snapshot()
    #expect(snapshot.0 == 0)
    #expect(snapshot.1 == 1)
}
