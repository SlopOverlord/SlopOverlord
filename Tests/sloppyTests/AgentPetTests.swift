import Foundation
import Testing
@testable import Protocols
@testable import sloppy

@Test
func userAgentGetsPetAndSystemAgentDoesNot() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = AgentCatalogFileStore(agentsRootURL: root)
    let models = [ProviderModelOption(id: "gpt-5.4-mini", title: "gpt-5.4 mini")]

    let user = try store.createAgent(
        AgentCreateRequest(id: "pet-user", displayName: "Pet User", role: "Builder"),
        availableModels: models
    )
    let system = try store.createAgent(
        AgentCreateRequest(id: "pet-system", displayName: "Pet System", role: "Daemon", isSystem: true),
        availableModels: models
    )

    #expect(user.pet != nil)
    #expect(user.pet?.currentStats == user.pet?.baseStats)
    #expect(user.pet?.visual != nil)
    #expect(user.pet?.evolution?.totalXp == 0)
    #expect(user.pet?.stageAssets.count == 3)
    #expect(system.pet == nil)

    let userPetState = root.appendingPathComponent("pet-user", isDirectory: true).appendingPathComponent("pet-state.json")
    let systemPetState = root.appendingPathComponent(".system/pet-system", isDirectory: true).appendingPathComponent("pet-state.json")
    #expect(FileManager.default.fileExists(atPath: userPetState.path))
    #expect(!FileManager.default.fileExists(atPath: systemPetState.path))
}

@Test
func legacyAgentGetsBackfilledPetOnRead() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = AgentCatalogFileStore(agentsRootURL: root)
    let agentDirectory = root.appendingPathComponent("legacy-agent", isDirectory: true)
    try FileManager.default.createDirectory(at: agentDirectory, withIntermediateDirectories: true)

    let legacy = AgentSummary(
        id: "legacy-agent",
        displayName: "Legacy Agent",
        role: "Support",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        isSystem: false,
        runtime: .init()
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try (encoder.encode(legacy) + Data("\n".utf8)).write(
        to: agentDirectory.appendingPathComponent("agent.json"),
        options: .atomic
    )

    let hydrated = try store.getAgent(id: "legacy-agent")
    #expect(hydrated.pet != nil)
    #expect(hydrated.pet?.currentStats == hydrated.pet?.baseStats)
    #expect(hydrated.pet?.visual != nil)
    #expect(FileManager.default.fileExists(atPath: agentDirectory.appendingPathComponent("pet-state.json").path))
}

@Test
func generatedPetDraftAttachesToCreatedAgent() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = AgentCatalogFileStore(agentsRootURL: root)
    let draft = AgentPetFactory.makePetDraft(
        request: AgentPetGenerationRequest(mode: .prompt, prompt: "a spark fox with a debugging bolt")
    )
    try store.writePetDraft(draft)

    let agent = try store.createAgent(
        AgentCreateRequest(
            id: "draft-pet-agent",
            displayName: "Draft Pet Agent",
            role: "Debugger",
            petDraftId: draft.draftId
        ),
        availableModels: [ProviderModelOption(id: "gpt-5.4-mini", title: "gpt-5.4 mini")]
    )

    #expect(agent.pet?.petId == draft.generated.summary.petId)
    #expect(agent.pet?.visual?.source == "prompt")
    #expect(agent.pet?.visual?.terminalFaceSet.idle.isEmpty == false)
    let archivedDraft = root
        .appendingPathComponent("draft-pet-agent", isDirectory: true)
        .appendingPathComponent(".sloppy/pets/\(draft.generated.summary.petId)/draft.json")
    #expect(FileManager.default.fileExists(atPath: archivedDraft.path))
}

@Test
func petEvolutionStageThresholdsMatchPlan() {
    #expect(AgentPetFactory.stage(for: 0) == 1)
    #expect(AgentPetFactory.stage(for: 119) == 1)
    #expect(AgentPetFactory.stage(for: 120) == 2)
    #expect(AgentPetFactory.stage(for: 319) == 2)
    #expect(AgentPetFactory.stage(for: 320) == 3)
}

@Test
func petProgressKeepsSmallPositiveActivityGains() {
    let baseStats = AgentPetStats(wisdom: 20, debugging: 20, patience: 20, snark: 20, chaos: 20)
    var state = AgentPetProgressState(currentStats: baseStats)

    AgentPetProgressionEngine.apply(
        state: &state,
        input: AgentPetProgressionInput(
            sourceKind: .agentSession,
            eventKind: .toolCall,
            channelId: "agent:pet-small-gain:session:s1",
            sessionId: "s1",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            content: "files.read"
        ),
        baseStats: baseStats
    )

    #expect(state.totalXp > 0)
    #expect(state.currentStats.debugging > baseStats.debugging)
}

@Test
func petProgressCombinesSourcesAndCapsRepeatedShortMessages() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = AgentCatalogFileStore(agentsRootURL: root)
    let agent = try store.createAgent(
        AgentCreateRequest(id: "progress-agent", displayName: "Progress Agent", role: "Debugger"),
        availableModels: [ProviderModelOption(id: "gpt-5.4-mini", title: "gpt-5.4 mini")]
    )
    let baseStats = try #require(agent.pet?.baseStats)

    _ = try store.recordPetInteraction(
        agentID: "progress-agent",
        input: AgentPetProgressionInput(
            sourceKind: .agentSession,
            eventKind: .userMessage,
            channelId: "agent:progress-agent:session:s1",
            sessionId: "s1",
            content: "Please debug this Swift build failure and explain the stack trace."
        )
    )
    _ = try store.recordPetInteraction(
        agentID: "progress-agent",
        input: AgentPetProgressionInput(
            sourceKind: .externalChannel,
            eventKind: .toolFailure,
            channelId: "discord-debug"
        )
    )
    _ = try store.recordPetInteraction(
        agentID: "progress-agent",
        input: AgentPetProgressionInput(
            sourceKind: .externalChannel,
            eventKind: .runCompleted,
            channelId: "discord-debug",
            content: "Issue resolved."
        )
    )

    for _ in 0..<40 {
        _ = try store.recordPetInteraction(
            agentID: "progress-agent",
            input: AgentPetProgressionInput(
                sourceKind: .externalChannel,
                eventKind: .userMessage,
                channelId: "discord-debug",
                content: "panic!!!"
            )
        )
    }

    let updated = try store.getAgent(id: "progress-agent")
    let currentStats = try #require(updated.pet?.currentStats)

    #expect(currentStats.wisdom >= baseStats.wisdom)
    #expect(currentStats.debugging >= baseStats.debugging)
    #expect(currentStats.chaos >= baseStats.chaos)
    #expect(currentStats.snark - baseStats.snark <= 10)
    #expect(currentStats.chaos - baseStats.chaos <= 12)
    #expect((updated.pet?.evolution?.totalXp ?? 0) > 0)
}

@Test
func petProgressTracksCoreServiceToolInvocationEvents() async throws {
    let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
    let agentID = "pet-tool-events-\(UUID().uuidString)"
    _ = try await service.createAgent(
        AgentCreateRequest(id: agentID, displayName: "Pet Tool Events", role: "Debugger")
    )
    let session = try await service.createAgentSession(
        agentID: agentID,
        request: AgentSessionCreateRequest(title: "Tool progress")
    )

    let before = try #require(try await service.getAgent(id: agentID).pet)
    let result = await service.invokeToolFromRuntime(
        agentID: agentID,
        sessionID: session.id,
        request: ToolInvocationRequest(tool: "system.list_tools")
    )

    #expect(result.ok)

    let updated = try await service.getAgent(id: agentID)
    let updatedPet = try #require(updated.pet)
    #expect((updatedPet.evolution?.totalXp ?? 0) > (before.evolution?.totalXp ?? 0))
    #expect(updatedPet.currentStats.debugging > before.currentStats.debugging)
}
