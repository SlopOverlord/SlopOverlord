import Foundation
import Testing
@testable import Core
@testable import Protocols

@Test
func toolsStoreAutoCreatesDefaultPolicy() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("tools-store-\(UUID().uuidString)", isDirectory: true)
    let agentsRoot = root.appendingPathComponent("agents", isDirectory: true)
    let agentDirectory = agentsRoot.appendingPathComponent("agent-1", isDirectory: true)
    try FileManager.default.createDirectory(at: agentDirectory, withIntermediateDirectories: true)

    let store = AgentToolsFileStore(agentsRootURL: agentsRoot)
    let policy = try store.getPolicy(agentID: "agent-1", knownToolIDs: ToolCatalog.knownToolIDs)

    #expect(policy.version == 1)
    #expect(policy.defaultPolicy == .allow)
    #expect(policy.tools.isEmpty)

    let toolsFile = agentDirectory.appendingPathComponent("tools/tools.json")
    #expect(FileManager.default.fileExists(atPath: toolsFile.path))
}

@Test
func toolsStoreSupportsDenyOverrides() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("tools-store-deny-\(UUID().uuidString)", isDirectory: true)
    let agentsRoot = root.appendingPathComponent("agents", isDirectory: true)
    let agentDirectory = agentsRoot.appendingPathComponent("agent-2", isDirectory: true)
    try FileManager.default.createDirectory(at: agentDirectory, withIntermediateDirectories: true)

    let store = AgentToolsFileStore(agentsRootURL: agentsRoot)
    _ = try store.getPolicy(agentID: "agent-2", knownToolIDs: ToolCatalog.knownToolIDs)

    let updated = try store.updatePolicy(
        agentID: "agent-2",
        request: AgentToolsUpdateRequest(
            version: 1,
            defaultPolicy: .allow,
            tools: ["agents.list": false],
            guardrails: .init()
        ),
        knownToolIDs: ToolCatalog.knownToolIDs
    )

    #expect(updated.tools["agents.list"] == false)
}

@Test
func authorizationHotReloadsPolicyByModificationDate() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("tools-store-hotreload-\(UUID().uuidString)", isDirectory: true)
    let agentsRoot = root.appendingPathComponent("agents", isDirectory: true)
    let agentDirectory = agentsRoot.appendingPathComponent("agent-3", isDirectory: true)
    try FileManager.default.createDirectory(at: agentDirectory, withIntermediateDirectories: true)

    let store = AgentToolsFileStore(agentsRootURL: agentsRoot)
    let auth = ToolAuthorizationService(store: store)
    _ = try await auth.policy(agentID: "agent-3")

    let denyPolicy = AgentToolsPolicy(
        version: 1,
        defaultPolicy: .deny,
        tools: [:],
        guardrails: .init()
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let payload = try encoder.encode(denyPolicy) + Data("\n".utf8)
    let toolsFile = agentDirectory.appendingPathComponent("tools/tools.json")
    try FileManager.default.createDirectory(at: toolsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try payload.write(to: toolsFile, options: .atomic)

    let decision = try await auth.authorize(agentID: "agent-3", toolID: "agents.list")
    #expect(decision.allowed == false)
    #expect(decision.error?.code == "tool_forbidden")
}
