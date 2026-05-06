import Foundation
import Protocols
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class ToolPreHookService: @unchecked Sendable {
    enum Source: String, Sendable {
        case agentSession = "agent_session"
        case channelRuntime = "channel_runtime"
    }

    enum Decision: Sendable {
        case allow(ToolInvocationRequest)
        case block(ToolInvocationResult)
    }

    private struct EffectiveConfig: Sendable {
        var enabled: Bool
        var command: String
        var arguments: [String]
        var timeoutMs: Int
        var maxOutputBytes: Int
        var failurePolicy: ToolHookFailurePolicy
    }

    private enum HookAction: String, Codable {
        case allow
        case block
    }

    private struct HookInput: Encodable {
        var version: Int
        var agentId: String
        var sessionId: String?
        var channelId: String?
        var source: String
        var tool: String
        var arguments: [String: JSONValue]
        var reason: String?
        var workingDirectory: String?
        var timestamp: String
    }

    private struct HookOutput: Decodable {
        var action: HookAction
        var arguments: [String: JSONValue]?
        var reason: String?
        var message: String?
    }

    private struct ProcessResult {
        var exitCode: Int32
        var stdout: Data
        var stderr: Data
        var timedOut: Bool
    }

    func evaluate(
        globalConfig: CoreConfig.ToolHooks.PreTools,
        agentOverride: AgentToolPreHookOverride,
        agentID: String,
        sessionID: String?,
        channelID: String?,
        source: Source,
        request: ToolInvocationRequest,
        workingDirectory: String?,
        workspaceRootURL: URL
    ) async -> Decision {
        let config = effectiveConfig(global: globalConfig, override: agentOverride)
        guard config.enabled else {
            return .allow(request)
        }

        do {
            let output = try runHook(
                config: config,
                agentID: agentID,
                sessionID: sessionID,
                channelID: channelID,
                source: source,
                request: request,
                workingDirectory: workingDirectory,
                workspaceRootURL: workspaceRootURL
            )
            switch output.action {
            case .allow:
                return .allow(
                    ToolInvocationRequest(
                        tool: request.tool,
                        arguments: output.arguments ?? request.arguments,
                        reason: output.reason ?? request.reason
                    )
                )
            case .block:
                return .block(blockedResult(tool: request.tool, message: output.message ?? "Tool call was blocked by pre-tools hook."))
            }
        } catch {
            if config.failurePolicy == .allow {
                return .allow(request)
            }
            return .block(
                blockedResult(
                    tool: request.tool,
                    code: "tool_pre_hook_failed",
                    message: "Pre-tools hook failed: \(error.localizedDescription)"
                )
            )
        }
    }

    private func effectiveConfig(
        global: CoreConfig.ToolHooks.PreTools,
        override: AgentToolPreHookOverride
    ) -> EffectiveConfig {
        EffectiveConfig(
            enabled: override.enabled ?? global.enabled,
            command: override.command ?? global.command,
            arguments: override.arguments ?? global.arguments,
            timeoutMs: max(1, override.timeoutMs ?? global.timeoutMs),
            maxOutputBytes: max(1, override.maxOutputBytes ?? global.maxOutputBytes),
            failurePolicy: override.failurePolicy ?? ToolHookFailurePolicy(rawValue: global.failurePolicy.rawValue) ?? .block
        )
    }

    private func runHook(
        config: EffectiveConfig,
        agentID: String,
        sessionID: String?,
        channelID: String?,
        source: Source,
        request: ToolInvocationRequest,
        workingDirectory: String?,
        workspaceRootURL: URL
    ) throws -> HookOutput {
        let commandURL = try resolveCommand(config.command, workspaceRootURL: workspaceRootURL)
        let input = HookInput(
            version: 1,
            agentId: agentID,
            sessionId: sessionID,
            channelId: channelID,
            source: source.rawValue,
            tool: request.tool,
            arguments: request.arguments,
            reason: request.reason,
            workingDirectory: workingDirectory,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
        let inputData = try JSONEncoder().encode(input)
        let result = try runProcess(
            executableURL: commandURL,
            arguments: config.arguments,
            input: inputData,
            timeoutMs: config.timeoutMs,
            maxOutputBytes: config.maxOutputBytes,
            workspaceRootURL: workspaceRootURL
        )

        if result.timedOut {
            throw ToolPreHookError.timeout
        }
        guard result.exitCode == 0 else {
            let stderr = String(data: result.stderr.prefix(2_048), encoding: .utf8) ?? ""
            throw ToolPreHookError.nonZeroExit(result.exitCode, stderr)
        }
        guard result.stdout.count <= config.maxOutputBytes else {
            throw ToolPreHookError.outputTooLarge
        }
        do {
            return try JSONDecoder().decode(HookOutput.self, from: result.stdout)
        } catch {
            throw ToolPreHookError.invalidOutput
        }
    }

    private func resolveCommand(_ rawCommand: String, workspaceRootURL: URL) throws -> URL {
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            throw ToolPreHookError.missingCommand
        }

        if command.hasPrefix("/") {
            return URL(fileURLWithPath: command).standardizedFileURL
        }

        let workspace = workspaceRootURL.standardizedFileURL
        let resolved = workspace.appendingPathComponent(command).standardizedFileURL
        guard resolved.path == workspace.path || resolved.path.hasPrefix(workspace.path + "/") else {
            throw ToolPreHookError.commandOutsideWorkspace
        }
        return resolved
    }

    private func runProcess(
        executableURL: URL,
        arguments: [String],
        input: Data,
        timeoutMs: Int,
        maxOutputBytes: Int,
        workspaceRootURL: URL
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = workspaceRootURL

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        stdin.fileHandleForWriting.write(input)
        try? stdin.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1_000.0)
        var timedOut = false
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            timedOut = true
            process.terminate()
            let terminateDeadline = Date().addingTimeInterval(0.2)
            while process.isRunning && Date() < terminateDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                forceKill(process)
            }
        }
        process.waitUntilExit()

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        if stdoutData.count > maxOutputBytes {
            throw ToolPreHookError.outputTooLarge
        }

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: stdoutData,
            stderr: stderrData,
            timedOut: timedOut
        )
    }

    private func forceKill(_ process: Process) {
        #if canImport(Darwin) || canImport(Glibc)
        kill(process.processIdentifier, SIGKILL)
        #else
        process.interrupt()
        #endif
    }

    private func blockedResult(
        tool: String,
        code: String = "tool_pre_hook_blocked",
        message: String
    ) -> ToolInvocationResult {
        ToolInvocationResult(
            tool: tool,
            ok: false,
            error: ToolErrorPayload(code: code, message: message, retryable: false)
        )
    }
}

private enum ToolPreHookError: LocalizedError {
    case missingCommand
    case commandOutsideWorkspace
    case timeout
    case nonZeroExit(Int32, String)
    case outputTooLarge
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .missingCommand:
            return "hook command is required"
        case .commandOutsideWorkspace:
            return "workspace-relative hook command resolves outside workspace"
        case .timeout:
            return "hook timed out"
        case .nonZeroExit(let code, let stderr):
            let suffix = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return suffix.isEmpty ? "hook exited with status \(code)" : "hook exited with status \(code): \(suffix)"
        case .outputTooLarge:
            return "hook output exceeded maxOutputBytes"
        case .invalidOutput:
            return "hook returned invalid JSON"
        }
    }
}
