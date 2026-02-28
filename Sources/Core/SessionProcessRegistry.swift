import Foundation
import Protocols

actor SessionProcessRegistry {
    enum RegistryError: Error {
        case processLimitReached
        case processNotFound
        case invalidPayload
        case launchFailed
    }

    private struct ManagedProcess {
        let id: String
        let command: String
        let arguments: [String]
        let cwd: String?
        let process: Process
        let startedAt: Date
        var finishedAt: Date?
        var exitCode: Int32?
    }

    private var processesBySession: [String: [String: ManagedProcess]] = [:]

    func activeCount(sessionID: String) -> Int {
        let processes = processesBySession[sessionID] ?? [:]
        return processes.values.filter { item in
            item.process.isRunning || item.exitCode == nil
        }.count
    }

    func start(
        sessionID: String,
        command: String,
        arguments: [String],
        cwd: String?,
        maxProcesses: Int
    ) throws -> JSONValue {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RegistryError.invalidPayload
        }

        let current = activeCount(sessionID: sessionID)
        if current >= maxProcesses {
            throw RegistryError.processLimitReached
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        if let cwd, !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        }

        do {
            try process.run()
        } catch {
            throw RegistryError.launchFailed
        }

        let id = "proc-\(UUID().uuidString.lowercased())"
        let now = Date()
        let managed = ManagedProcess(
            id: id,
            command: command,
            arguments: arguments,
            cwd: cwd,
            process: process,
            startedAt: now,
            finishedAt: nil,
            exitCode: nil
        )
        var sessionProcesses = processesBySession[sessionID] ?? [:]
        sessionProcesses[id] = managed
        processesBySession[sessionID] = sessionProcesses

        return .object([
            "processId": .string(id),
            "pid": .number(Double(process.processIdentifier)),
            "running": .bool(true),
            "startedAt": .string(iso8601(now))
        ])
    }

    func status(sessionID: String, processID: String) throws -> JSONValue {
        guard var sessionProcesses = processesBySession[sessionID],
              var process = sessionProcesses[processID] else {
            throw RegistryError.processNotFound
        }

        process = refreshed(process)
        sessionProcesses[processID] = process
        processesBySession[sessionID] = sessionProcesses
        return processPayload(process)
    }

    func stop(sessionID: String, processID: String) throws -> JSONValue {
        guard var sessionProcesses = processesBySession[sessionID],
              var process = sessionProcesses[processID] else {
            throw RegistryError.processNotFound
        }

        if process.process.isRunning {
            process.process.terminate()
            process.process.waitUntilExit()
        }
        process = refreshed(process)
        sessionProcesses[processID] = process
        processesBySession[sessionID] = sessionProcesses
        return processPayload(process)
    }

    func list(sessionID: String) -> JSONValue {
        let sessionProcesses = processesBySession[sessionID] ?? [:]
        let items = sessionProcesses.values
            .map(refreshed)
            .sorted { $0.startedAt > $1.startedAt }

        var refreshedSessionMap: [String: ManagedProcess] = [:]
        for item in items {
            refreshedSessionMap[item.id] = item
        }
        processesBySession[sessionID] = refreshedSessionMap

        return .array(items.map(processPayload))
    }

    func cleanup(sessionID: String) {
        guard let sessionProcesses = processesBySession[sessionID] else {
            return
        }
        for process in sessionProcesses.values where process.process.isRunning {
            process.process.terminate()
            process.process.waitUntilExit()
        }
        processesBySession.removeValue(forKey: sessionID)
    }

    func shutdown() {
        for sessionID in processesBySession.keys {
            cleanup(sessionID: sessionID)
        }
    }

    private func refreshed(_ process: ManagedProcess) -> ManagedProcess {
        guard !process.process.isRunning else {
            return process
        }

        if process.exitCode != nil {
            return process
        }

        var copy = process
        copy.exitCode = process.process.terminationStatus
        copy.finishedAt = Date()
        return copy
    }

    private func processPayload(_ process: ManagedProcess) -> JSONValue {
        .object([
            "processId": .string(process.id),
            "command": .string(process.command),
            "arguments": .array(process.arguments.map { .string($0) }),
            "cwd": process.cwd.map(JSONValue.string) ?? .null,
            "running": .bool(process.process.isRunning),
            "startedAt": .string(iso8601(process.startedAt)),
            "finishedAt": process.finishedAt.map { .string(iso8601($0)) } ?? .null,
            "exitCode": process.exitCode.map { .number(Double($0)) } ?? .null
        ])
    }

    private func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
