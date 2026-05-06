import Foundation
import Testing
@testable import sloppy

@Test("MCP status reports disabled and invalid servers")
func mcpServerStatusesReportDisabledAndInvalidServers() async {
    let registry = MCPClientRegistry(
        config: CoreConfig.MCP(
            servers: [
                .init(id: "off", enabled: false),
                .init(id: "bad-stdio", transport: .stdio, command: nil)
            ]
        )
    )

    let statuses = await registry.serverStatuses()

    #expect(statuses.count == 2)
    #expect(statuses[0].id == "off")
    #expect(statuses[0].enabled == false)
    #expect(statuses[0].connected == false)
    #expect(statuses[0].message == "disabled")

    #expect(statuses[1].id == "bad-stdio")
    #expect(statuses[1].enabled)
    #expect(statuses[1].connected == false)
    #expect(statuses[1].message?.contains("command is missing") == true)
}

@Test("MCP status reports missing stdio commands")
func mcpServerStatusesReportMissingCommands() async {
    let missingCommand = "sloppy-mcp-command-missing-\(UUID().uuidString)"
    let registry = MCPClientRegistry(
        config: CoreConfig.MCP(
            servers: [
                .init(id: "missing", transport: .stdio, command: missingCommand, timeoutMs: 50)
            ]
        )
    )

    let statuses = await registry.serverStatuses()

    #expect(statuses.count == 1)
    #expect(statuses[0].id == "missing")
    #expect(statuses[0].connected == false)
    #expect(statuses[0].message?.contains("Command not found: \(missingCommand)") == true)
}

@Test("Tool catalog keeps built-ins when MCP discovery fails")
func toolCatalogReturnsBuiltInsWhenMCPDiscoveryFails() async {
    let missingCommand = "sloppy-mcp-discovery-missing-\(UUID().uuidString)"
    let registry = MCPClientRegistry(
        config: CoreConfig.MCP(
            servers: [
                .init(id: "broken", transport: .stdio, command: missingCommand, timeoutMs: 50)
            ]
        )
    )

    let entries = await ToolCatalog.entries(mcpRegistry: registry)
    let ids = Set(entries.map(\.id))

    #expect(ids.contains("memory.save"))
    #expect(ids.contains("system.list_tools"))
}

@Test("CoreService exposes MCP runtime statuses")
func coreServiceExposesMCPRuntimeStatuses() async {
    var config = CoreConfig.test
    config.mcp = CoreConfig.MCP(
        servers: [
            .init(id: "off", enabled: false)
        ]
    )
    let service = CoreService(config: config, persistenceBuilder: InMemoryCorePersistenceBuilder())

    let statuses = await service.listMCPServerStatuses()

    #expect(statuses.count == 1)
    #expect(statuses[0].id == "off")
    #expect(statuses[0].message == "disabled")
}
