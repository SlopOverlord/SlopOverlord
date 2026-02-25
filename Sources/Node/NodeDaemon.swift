import Foundation
import Protocols

public struct ProcessResult: Codable, Sendable, Equatable {
    public var command: String
    public var arguments: [String]
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public init(command: String, arguments: [String], exitCode: Int32, stdout: String, stderr: String) {
        self.command = command
        self.arguments = arguments
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public actor NodeDaemon {
    public enum State: String, Sendable {
        case idle
        case connected
        case runningTask
    }

    public let nodeId: String
    public private(set) var state: State = .idle
    public private(set) var lastHeartbeatAt: Date?

    public init(nodeId: String = UUID().uuidString) {
        self.nodeId = nodeId
    }

    /// Marks daemon as connected and initializes heartbeat timestamp.
    public func connect() {
        state = .connected
        lastHeartbeatAt = Date()
    }

    /// Updates heartbeat timestamp for connection liveness.
    public func heartbeat() {
        lastHeartbeatAt = Date()
    }

    /// Spawns child process and returns captured output.
    public func spawnProcess(command: String, arguments: [String]) async throws -> ProcessResult {
        state = .runningTask
        defer { state = .connected }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        return ProcessResult(
            command: command,
            arguments: arguments,
            exitCode: process.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self)
        )
    }

    /// Reads UTF-8 text file from disk.
    public func readText(at path: String) throws -> String {
        try String(contentsOfFile: path)
    }

    /// Writes UTF-8 text file to disk creating parent directory when required.
    public func writeText(_ content: String, to path: String) throws {
        let fileURL = URL(fileURLWithPath: path)
        let directory = fileURL.deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try content.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
