import AnyLanguageModel
import AgentRuntime
import Foundation
import Logging
import Protocols

// MARK: - CoreTool

/// Bridge protocol that extends AnyLanguageModel's `Tool` for use in the Sloppy runtime.
///
/// Each tool conforms to `CoreTool` and is registered in `ToolRegistry`. The `invoke` method
/// is the adapter entry point called by `ToolExecutionService`; `call(arguments:)` is the
/// AnyLanguageModel-facing stub for future LanguageModelSession integration.
protocol CoreTool: Tool, Sendable where Arguments == GeneratedContent, Output == String {
    var toolID: String { get }
    var domain: String { get }
    var title: String { get }
    var status: String { get }
    /// Additional IDs this tool handles (aliases).
    var toolAliases: [String] { get }

    func invoke(arguments: [String: JSONValue], context: ToolContext) async -> ToolInvocationResult
}

extension CoreTool {
    var toolID: String { name }
    var toolAliases: [String] { [] }

    func call(arguments: GeneratedContent) async throws -> String { "" }
}

// MARK: - ToolContext

/// Per-invocation context carrying all service dependencies needed by tools.
struct ToolContext: @unchecked Sendable {
    let agentID: String
    let sessionID: String
    let policy: AgentToolsPolicy
    let workspaceRootURL: URL
    let currentDirectoryURL: URL
    let runtime: RuntimeSystem
    let memoryStore: any MemoryStore
    let sessionStore: AgentSessionFileStore
    let agentCatalogStore: AgentCatalogFileStore
    let agentSkillsStore: AgentSkillsFileStore?
    let processRegistry: SessionProcessRegistry
    let browserService: BrowserCDPService
    let channelSessionStore: ChannelSessionFileStore
    let store: any PersistenceStore
    let searchProviderService: SearchProviderService
    let mcpRegistry: MCPClientRegistry
    let logger: Logger
    let projectService: (any ProjectToolService)?
    let configService: (any RuntimeConfigToolService)?
    let skillsService: (any SkillsToolService)?
    let lspManager: LSPServerManager?
    /// When set, updates `USER.md` / `MEMORY.md` through the same validation path as the HTTP API.
    let applyAgentMarkdown: ((AgentMarkdownDocumentField, String) async throws -> Void)?
    /// Runs an isolated subagent session; set by `CoreService.configureToolExecutionServices`.
    let delegateSubagent: (@Sendable (String, String, String, String?, [String]?, String?, String?) async -> String?)?

    init(
        agentID: String,
        sessionID: String,
        policy: AgentToolsPolicy,
        workspaceRootURL: URL,
        currentDirectoryURL: URL? = nil,
        runtime: RuntimeSystem,
        memoryStore: any MemoryStore,
        sessionStore: AgentSessionFileStore,
        agentCatalogStore: AgentCatalogFileStore,
        agentSkillsStore: AgentSkillsFileStore?,
        processRegistry: SessionProcessRegistry,
        channelSessionStore: ChannelSessionFileStore,
        store: any PersistenceStore,
        searchProviderService: SearchProviderService,
        mcpRegistry: MCPClientRegistry,
        logger: Logger,
        projectService: (any ProjectToolService)?,
        configService: (any RuntimeConfigToolService)?,
        skillsService: (any SkillsToolService)?,
        lspManager: LSPServerManager?,
        browserService: BrowserCDPService? = nil,
        applyAgentMarkdown: ((AgentMarkdownDocumentField, String) async throws -> Void)?,
        delegateSubagent: (@Sendable (String, String, String, String?, [String]?, String?, String?) async -> String?)?
    ) {
        self.agentID = agentID
        self.sessionID = sessionID
        self.policy = policy
        self.workspaceRootURL = workspaceRootURL
        self.currentDirectoryURL = currentDirectoryURL ?? workspaceRootURL
        self.runtime = runtime
        self.memoryStore = memoryStore
        self.sessionStore = sessionStore
        self.agentCatalogStore = agentCatalogStore
        self.agentSkillsStore = agentSkillsStore
        self.processRegistry = processRegistry
        self.browserService = browserService ?? BrowserCDPService(config: .init(), workspaceRootURL: workspaceRootURL)
        self.channelSessionStore = channelSessionStore
        self.store = store
        self.searchProviderService = searchProviderService
        self.mcpRegistry = mcpRegistry
        self.logger = logger
        self.projectService = projectService
        self.configService = configService
        self.skillsService = skillsService
        self.lspManager = lspManager
        self.applyAgentMarkdown = applyAgentMarkdown
        self.delegateSubagent = delegateSubagent
    }
}

// MARK: - ProjectToolService

/// Operations backed by CoreService that project and actor tools require.
/// CoreService conforms to this protocol to provide actor-isolated access.
protocol ProjectToolService: Sendable {
    func findProjectForChannel(channelId: String, topicId: String?) async -> ProjectRecord?
    func getProject(id: String) async throws -> ProjectRecord
    func createTask(projectID: String, request: ProjectTaskCreateRequest) async throws -> ProjectRecord
    func updateTask(projectID: String, taskID: String, request: ProjectTaskUpdateRequest) async throws -> ProjectRecord
    func cancelTaskWithReason(projectID: String, taskID: String, reason: String?) async throws -> ProjectRecord
    func deleteTask(projectID: String, taskID: String) async throws -> ProjectRecord
    func getTask(reference: String) async throws -> AgentTaskRecord
    func createTaskClarification(projectID: String, taskID: String, request: TaskClarificationCreateRequest) async throws -> TaskClarificationRecord
    func deliverMessage(channelId: String, content: String) async
    func actorBoard() async throws -> ActorBoardSnapshot
    func requestProjectMemoryCheckpoint(agentID: String, sessionID: String, projectID: String, taskID: String, status: String) async

    func listAllProjects() async -> [ProjectRecord]
    func createProject(_ request: ProjectCreateRequest) async throws -> ProjectCreateResult
    func updateProject(projectID: String, request: ProjectUpdateRequest) async throws -> ProjectRecord
    func linkProjectChannel(projectID: String, request: ProjectChannelLinkRequest) async throws -> ProjectChannelLinkResponse
    func deleteProject(projectID: String) async throws
}

protocol RuntimeConfigToolService: Sendable {
    func runtimeConfig() async -> CoreConfig
    func updateRuntimeConfig(_ config: CoreConfig) async throws -> CoreConfig
}

protocol SkillsToolService: Sendable {
    func fetchSkillsRegistry(search: String?, sort: String, limit: Int, offset: Int) async throws -> SkillsRegistryResponse
    func listAgentSkills(agentID: String) async throws -> AgentSkillsResponse
    func installAgentSkill(agentID: String, request: SkillInstallRequest) async throws -> InstalledSkill
    func uninstallAgentSkill(agentID: String, skillID: String) async throws
}

// MARK: - Argument resolution helpers

private let sessionIDPlaceholders: Set<String> = ["current", "self", "this"]

func resolveSessionID(_ raw: String?, context: ToolContext) -> String {
    guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
          !raw.isEmpty,
          !sessionIDPlaceholders.contains(raw.lowercased())
    else {
        return context.sessionID
    }
    return raw
}

// MARK: - Result helpers

func toolSuccess(tool: String, data: JSONValue) -> ToolInvocationResult {
    ToolInvocationResult(tool: tool, ok: true, data: data)
}

func toolFailure(tool: String, code: String, message: String, retryable: Bool, hint: String? = nil) -> ToolInvocationResult {
    ToolInvocationResult(
        tool: tool,
        ok: false,
        error: ToolErrorPayload(code: code, message: message, retryable: retryable, hint: hint)
    )
}

// MARK: - GenerationSchema helpers

extension GenerationSchema {
    /// Builds an object schema from a list of DynamicGenerationSchema.Property descriptors.
    static func objectSchema(_ properties: [DynamicGenerationSchema.Property]) -> GenerationSchema {
        let schema = DynamicGenerationSchema(name: "Arguments", properties: properties)
        return (try? GenerationSchema(root: schema, dependencies: [])) ?? String.generationSchema
    }
}
