import Foundation
import Testing
@testable import sloppy
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
    #expect(policy.approval.enabled == false)

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

@Test
func authorizationAllowsSystemListToolsFromCatalog() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("tools-store-system-list-\(UUID().uuidString)", isDirectory: true)
    let agentsRoot = root.appendingPathComponent("agents", isDirectory: true)
    let agentDirectory = agentsRoot.appendingPathComponent("agent-4", isDirectory: true)
    try FileManager.default.createDirectory(at: agentDirectory, withIntermediateDirectories: true)

    #expect(ToolCatalog.knownToolIDs.contains("system.list_tools"))

    let store = AgentToolsFileStore(agentsRootURL: agentsRoot)
    let auth = ToolAuthorizationService(store: store)
    let decision = try await auth.authorize(agentID: "agent-4", toolID: "system.list_tools")

    #expect(decision.allowed == true)
    #expect(decision.error == nil)
}

@Test
func authorizationAllowsBuiltInToolWithoutMCPDiscovery() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("tools-store-builtin-no-mcp-\(UUID().uuidString)", isDirectory: true)
    let agentsRoot = root.appendingPathComponent("agents", isDirectory: true)
    let agentDirectory = agentsRoot.appendingPathComponent("agent-built-in", isDirectory: true)
    try FileManager.default.createDirectory(at: agentDirectory, withIntermediateDirectories: true)

    let discovery = SpyMCPToolDiscovery(dynamicToolIDs: ["remote.echo"])
    let store = AgentToolsFileStore(agentsRootURL: agentsRoot)
    let auth = ToolAuthorizationService(store: store, mcpRegistry: discovery)

    let decision = try await auth.authorize(agentID: "agent-built-in", toolID: "memory.save")

    #expect(decision.allowed == true)
    #expect(decision.error == nil)
    #expect(await discovery.dynamicToolIDCallCount() == 0)
    #expect(await discovery.dynamicToolsCallCount() == 0)
}

@Test
func authorizationChecksMCPDiscoveryForDynamicTool() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("tools-store-dynamic-mcp-\(UUID().uuidString)", isDirectory: true)
    let agentsRoot = root.appendingPathComponent("agents", isDirectory: true)
    let agentDirectory = agentsRoot.appendingPathComponent("agent-dynamic", isDirectory: true)
    try FileManager.default.createDirectory(at: agentDirectory, withIntermediateDirectories: true)

    let discovery = SpyMCPToolDiscovery(dynamicToolIDs: ["remote.echo"])
    let store = AgentToolsFileStore(agentsRootURL: agentsRoot)
    let auth = ToolAuthorizationService(store: store, mcpRegistry: discovery)

    let decision = try await auth.authorize(agentID: "agent-dynamic", toolID: "remote.echo")

    #expect(decision.allowed == true)
    #expect(decision.error == nil)
    #expect(await discovery.dynamicToolIDCallCount() == 1)
}

@Test
func toolsStoreLoadsLegacyGuardrailsWithLoopDefaults() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("tools-store-legacy-\(UUID().uuidString)", isDirectory: true)
    let agentsRoot = root.appendingPathComponent("agents", isDirectory: true)
    let agentDirectory = agentsRoot.appendingPathComponent("agent-legacy", isDirectory: true)
    let toolsDirectory = agentDirectory.appendingPathComponent("tools", isDirectory: true)
    try FileManager.default.createDirectory(at: toolsDirectory, withIntermediateDirectories: true)

    let legacyJSON = """
    {
      "version": 1,
      "defaultPolicy": "allow",
      "tools": {},
      "guardrails": {
        "maxReadBytes": 524288,
        "maxWriteBytes": 524288,
        "execTimeoutMs": 15000,
        "maxExecOutputBytes": 262144,
        "maxProcessesPerSession": 2,
        "maxToolCallsPerMinute": 60,
        "deniedCommandPrefixes": ["rm"],
        "allowedWriteRoots": [],
        "allowedExecRoots": [],
        "webTimeoutMs": 10000,
        "webMaxBytes": 524288,
        "webBlockPrivateNetworks": true
      }
    }
    """
    try Data(legacyJSON.utf8).write(to: toolsDirectory.appendingPathComponent("tools.json"))

    let store = AgentToolsFileStore(agentsRootURL: agentsRoot)
    let policy = try store.getPolicy(agentID: "agent-legacy", knownToolIDs: ToolCatalog.knownToolIDs)

    #expect(policy.guardrails.toolLoopWindowSeconds == 60)
    #expect(policy.guardrails.maxConsecutiveIdenticalToolCalls == 3)
    #expect(policy.guardrails.maxIdenticalToolCallsPerWindow == 6)
    #expect(policy.guardrails.maxRepeatedNonRetryableFailures == 2)
    #expect(policy.guardrails.maxExecTimeoutMs == 120_000)
    #expect(policy.approval.enabled == false)
}

private actor SpyMCPToolDiscovery: MCPToolDiscovering {
    private let ids: Set<String>
    private var idCalls = 0
    private var toolsCalls = 0

    init(dynamicToolIDs: Set<String>) {
        self.ids = dynamicToolIDs
    }

    func dynamicTools() async -> [MCPDynamicTool] {
        toolsCalls += 1
        return []
    }

    func dynamicToolIDs() async -> Set<String> {
        idCalls += 1
        return ids
    }

    func dynamicToolIDCallCount() -> Int {
        idCalls
    }

    func dynamicToolsCallCount() -> Int {
        toolsCalls
    }
}
