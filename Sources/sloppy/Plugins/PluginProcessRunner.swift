import Foundation

struct PluginProcessResult: Sendable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
}

protocol PluginProcessRunning: Sendable {
    func run(
        _ executable: String,
        arguments: [String],
        cwd: URL?
    ) async throws -> PluginProcessResult
}

struct LivePluginProcessRunner: PluginProcessRunning {
    func run(
        _ executable: String,
        arguments: [String],
        cwd: URL? = nil
    ) async throws -> PluginProcessResult {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
            process.currentDirectoryURL = cwd
            process.environment = childProcessEnvironment()

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let stdoutBuffer = PluginProcessOutputBuffer()
            let stderrBuffer = PluginProcessOutputBuffer()

            try process.run()

            let stdoutTask = Task.detached {
                stdoutBuffer.data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            }
            let stderrTask = Task.detached {
                stderrBuffer.data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            }

            process.waitUntilExit()
            await stdoutTask.value
            await stderrTask.value

            return PluginProcessResult(
                exitCode: process.terminationStatus,
                stdout: String(data: stdoutBuffer.data, encoding: .utf8) ?? "",
                stderr: String(data: stderrBuffer.data, encoding: .utf8) ?? ""
            )
        }.value
    }
}

private final class PluginProcessOutputBuffer: @unchecked Sendable {
    var data = Data()
}
