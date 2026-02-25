import Foundation
import Protocols

public protocol GatewayPlugin: Sendable {
    var id: String { get }
    func start() async throws
    func stop() async
    func send(channelId: String, message: String) async throws
}

public protocol ToolPlugin: Sendable {
    var id: String { get }
    var supportedTools: [String] { get }
    func invoke(tool: String, arguments: [String: JSONValue]) async throws -> JSONValue
}

public protocol MemoryPlugin: Sendable {
    var id: String { get }
    func recall(query: String, limit: Int) async throws -> [MemoryRef]
    func save(note: String) async throws -> MemoryRef
}

public protocol ModelProviderPlugin: Sendable {
    var id: String { get }
    var models: [String] { get }
    func complete(model: String, prompt: String, maxTokens: Int) async throws -> String
}
