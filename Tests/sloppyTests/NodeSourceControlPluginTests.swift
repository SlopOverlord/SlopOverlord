import Foundation
import Testing
@testable import sloppy
@testable import Protocols
@testable import PluginSDK

@Suite("Node source-control plugins")
struct NodeSourceControlPluginTests {
    @Test
    func commandAdapterCreatesWorktreeAndReturnsDiff() async throws {
        guard nodeIsAvailable() else {
            return
        }

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let pluginDir = root.appendingPathComponent("Plugins/command-source-control", isDirectory: true)
        let repoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sloppy-node-source-control-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repoURL) }

        let manifest = PluginManifest(
            name: "command-source-control",
            protocol: "source_control",
            runtime: .nodejs,
            entrypoint: "index.js",
            config: [
                "displayName": .string("Command Source Control"),
                "worktreeRootName": .string(".sloppy-worktree"),
                "capabilities": .array([.string("worktrees"), .string("working_tree_diff")]),
                "commands": .object([
                    "createWorktree": .string("mkdir -p {worktreePath}"),
                    "workingTreeDiff": .string("printf 'diff --git a/file.txt b/file.txt\\n+hello\\n'"),
                ]),
            ]
        )
        let provider = try NodeSourceControlProvider(manifest: manifest, pluginDirectory: pluginDir)

        let worktree = try await provider.createWorktree(repoPath: repoURL.path, taskId: "task-1", baseBranch: "HEAD")
        #expect(worktree.worktreePath == repoURL.appendingPathComponent(".sloppy-worktree/task-1").path)
        #expect(worktree.branchName == "sloppy/task-1")
        #expect(FileManager.default.fileExists(atPath: worktree.worktreePath))

        let diff = try await provider.workingTreeDiff(at: worktree.worktreePath, maxBytes: 1024)
        #expect(diff.providerId == "command-source-control")
        #expect(diff.text.contains("+hello"))
    }

    @Test
    func commandAdapterReportsUnsupportedOperations() async throws {
        guard nodeIsAvailable() else {
            return
        }

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let pluginDir = root.appendingPathComponent("Plugins/command-source-control", isDirectory: true)
        let manifest = PluginManifest(
            name: "command-source-control",
            protocol: "source_control",
            runtime: .nodejs,
            entrypoint: "index.js",
            config: [:]
        )
        let provider = try NodeSourceControlProvider(manifest: manifest, pluginDirectory: pluginDir)

        do {
            _ = try await provider.createWorktree(repoPath: "/tmp/repo", taskId: "task-1", baseBranch: "HEAD")
            Issue.record("Expected unsupported createWorktree to throw.")
        } catch let error as SourceControlProviderError {
            guard case .unsupportedOperation = error else {
                Issue.record("Expected unsupportedOperation, got \(error).")
                return
            }
        }
    }
}

private func nodeIsAvailable() -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["node", "--version"]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}
