import Foundation
import Protocols

/// Wraps a tool plugin implementation for return through `sloppy_tool_create`.
public final class AnyToolPluginBox: ToolPlugin, @unchecked Sendable {
    public let id: String
    public let supportedTools: [String]

    private let _invoke: @Sendable (String, [String: JSONValue]) async throws -> JSONValue

    public init(
        id: String,
        supportedTools: [String],
        invoke: @escaping @Sendable (String, [String: JSONValue]) async throws -> JSONValue
    ) {
        self.id = id
        self.supportedTools = supportedTools
        self._invoke = invoke
    }

    public func invoke(tool: String, arguments: [String: JSONValue]) async throws -> JSONValue {
        try await _invoke(tool, arguments)
    }
}
