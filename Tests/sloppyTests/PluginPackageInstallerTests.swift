import Foundation
import Testing
import PluginSDK
import Protocols
@testable import sloppy

private actor FakePluginProcessRunner: PluginProcessRunning {
    private var recordedCommands: [(executable: String, arguments: [String], cwd: String?)] = []

    func run(
        _ executable: String,
        arguments: [String],
        cwd: URL?
    ) async throws -> PluginProcessResult {
        recordedCommands.append((executable: executable, arguments: arguments, cwd: cwd?.path))

        if executable == "git", arguments.first == "clone" {
            let source = URL(fileURLWithPath: arguments[1], isDirectory: true)
            let destination = URL(fileURLWithPath: arguments[2], isDirectory: true)
            try FileManager.default.copyItem(at: source, to: destination)
            return PluginProcessResult(exitCode: 0, stdout: "", stderr: "")
        }

        if executable == "git", arguments == ["rev-parse", "HEAD"] {
            return PluginProcessResult(exitCode: 0, stdout: "deadbeef\n", stderr: "")
        }

        if executable == "swift", arguments == ["--version"] {
            return PluginProcessResult(exitCode: 0, stdout: "Swift fake 6.2\n", stderr: "")
        }

        if executable == "swift", arguments.contains("--show-bin-path") {
            let binPath = try #require(cwd)
                .appendingPathComponent(".build/release", isDirectory: true)
            try FileManager.default.createDirectory(at: binPath, withIntermediateDirectories: true)
            return PluginProcessResult(exitCode: 0, stdout: "\(binPath.path)\n", stderr: "")
        }

        if executable == "swift", arguments.starts(with: ["build", "-c", "release", "--product"]) {
            let product = try #require(arguments.last)
            let binPath = try #require(cwd)
                .appendingPathComponent(".build/release", isDirectory: true)
            try FileManager.default.createDirectory(at: binPath, withIntermediateDirectories: true)
            let artifact = binPath.appendingPathComponent("lib\(product).dylib")
            if product == "task-sync-plugin" {
                try Self.compileTaskSyncEntrypointDylib(to: artifact)
            } else {
                try Data("binary".utf8).write(to: artifact)
            }
            return PluginProcessResult(exitCode: 0, stdout: "", stderr: "")
        }

        return PluginProcessResult(exitCode: 0, stdout: "", stderr: "")
    }

    func commands() -> [(executable: String, arguments: [String], cwd: String?)] {
        recordedCommands
    }

    private static func compileTaskSyncEntrypointDylib(to artifact: URL) throws {
        let sourceURL = artifact.deletingLastPathComponent().appendingPathComponent("TaskSyncEntrypoint.swift")
        let source = """
        import Foundation

        @_cdecl(\"sloppy_task_sync_create\")
        public func sloppy_task_sync_create(_ manifestJSON: UnsafePointer<CChar>) -> UnsafeMutableRawPointer? {
            nil
        }
        """
        try Data(source.utf8).write(to: sourceURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
        process.arguments = ["-emit-library", "-o", artifact.path, sourceURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(decoding: data, as: UTF8.self)
            throw PluginPackageBuildError.swiftCommandFailed(
                command: "swiftc -emit-library",
                exitCode: process.terminationStatus,
                output: output
            )
        }
    }
}

@Test
func sourcePluginInstallerClonesBuildsAndReusesCache() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("plugin-install-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let source = root.appendingPathComponent("source", isDirectory: true)
    try makeSourcePlugin(at: source, name: "sample-plugin")

    let runner = FakePluginProcessRunner()
    let installer = PluginPackageInstaller(
        pluginsRootURL: root.appendingPathComponent("plugins", isDirectory: true),
        cacheRootURL: root.appendingPathComponent("plugin-cache", isDirectory: true),
        processRunner: runner
    )

    let first = try await installer.install(
        ChannelPluginInstallRequest(sourceUrl: source.path)
    )
    #expect(first.manifest.name == "sample-plugin")
    #expect(first.rebuilt == true)
    #expect(FileManager.default.fileExists(atPath: first.sourceURL.appendingPathComponent("plugin.json").path))
    let firstBinaryURL = try #require(first.binaryURL)
    #expect(FileManager.default.fileExists(atPath: firstBinaryURL.path))

    let commandsAfterFirst = await runner.commands()
    #expect(commandsAfterFirst.contains(where: { $0.executable == "git" && $0.arguments.first == "clone" }))
    #expect(commandsAfterFirst.filter { $0.executable == "swift" && $0.arguments.contains("--product") }.count == 1)

    let second = try await installer.install(
        ChannelPluginInstallRequest(sourceUrl: source.path, force: true)
    )
    #expect(second.rebuilt == false)
    #expect(second.binaryURL?.path == firstBinaryURL.path)

    let commandsAfterSecond = await runner.commands()
    #expect(commandsAfterSecond.filter { $0.executable == "swift" && $0.arguments.contains("--product") }.count == 1)
}

@Test
func sourcePluginInstallerRejectsExistingPluginWithoutForce() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("plugin-conflict-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let source = root.appendingPathComponent("source", isDirectory: true)
    try makeSourcePlugin(at: source, name: "conflict-plugin")
    let pluginsRoot = root.appendingPathComponent("plugins", isDirectory: true)
    try FileManager.default.createDirectory(
        at: pluginsRoot.appendingPathComponent("conflict-plugin", isDirectory: true),
        withIntermediateDirectories: true
    )

    let installer = PluginPackageInstaller(
        pluginsRootURL: pluginsRoot,
        cacheRootURL: root.appendingPathComponent("plugin-cache", isDirectory: true),
        processRunner: FakePluginProcessRunner()
    )

    await #expect(throws: PluginPackageInstallError.self) {
        _ = try await installer.install(ChannelPluginInstallRequest(sourceUrl: source.path))
    }
}

@Test
func sourcePluginInstallerAcceptsTaskSyncProtocol() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("plugin-task-sync-validation-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try makeSourcePlugin(at: root, name: "task-sync-plugin", pluginProtocol: "task_sync")
    let installer = PluginPackageInstaller(
        pluginsRootURL: root.appendingPathComponent("plugins", isDirectory: true),
        cacheRootURL: root.appendingPathComponent("plugin-cache", isDirectory: true),
        processRunner: FakePluginProcessRunner()
    )

    let manifest = try installer.validateSourcePackage(at: root)
    #expect(manifest.name == "task-sync-plugin")
    #expect(manifest.protocol == "task_sync")
}

@Test
func pluginManifestRuntimeUsesCanonicalNamesAndDecodesLegacyAliases() throws {
    let legacySwift = try JSONDecoder().decode(
        PluginManifest.self,
        from: Data(#"{"name":"legacy-swift","protocol":"tool","runtime":"swift-dylib"}"#.utf8)
    )
    let legacyNode = try JSONDecoder().decode(
        PluginManifest.self,
        from: Data(#"{"name":"legacy-node","protocol":"tool","runtime":"node","entrypoint":"index.js"}"#.utf8)
    )
    let currentNode = try JSONDecoder().decode(
        PluginManifest.self,
        from: Data(#"{"name":"current-node","protocol":"tool","runtime":"nodejs","entrypoint":"index.js"}"#.utf8)
    )
    let defaultRuntime = try JSONDecoder().decode(
        PluginManifest.self,
        from: Data(#"{"name":"default-swift","protocol":"tool"}"#.utf8)
    )

    #expect(legacySwift.runtime == .swift)
    #expect(legacyNode.runtime == .nodejs)
    #expect(currentNode.runtime == .nodejs)
    #expect(defaultRuntime.runtime == .swift)

    let encoded = try JSONEncoder().encode(currentNode)
    let payload = try #require(String(data: encoded, encoding: .utf8))
    #expect(payload.contains(#""runtime":"nodejs""#))
}

@Test
func sourcePluginInstallerAcceptsAllPluginProtocolsAndNodejsRuntime() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("plugin-protocol-validation-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let installer = PluginPackageInstaller(
        pluginsRootURL: root.appendingPathComponent("plugins", isDirectory: true),
        cacheRootURL: root.appendingPathComponent("plugin-cache", isDirectory: true),
        processRunner: FakePluginProcessRunner()
    )

    for pluginProtocol in ["gateway", "task_sync", "source_control", "tool", "memory", "model_provider"] {
        let source = root.appendingPathComponent(pluginProtocol, isDirectory: true)
        if pluginProtocol == "gateway" {
            try makeSourcePlugin(at: source, name: "\(pluginProtocol)-plugin", pluginProtocol: pluginProtocol)
        } else {
            try makeNodePlugin(at: source, name: "\(pluginProtocol)-plugin", pluginProtocol: pluginProtocol)
        }
        let manifest = try installer.validateSourcePackage(at: source)
        #expect(manifest.protocol == pluginProtocol)
    }
}

@Test
func sourcePluginInstallerRejectsInvalidManifestProtocol() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("plugin-validation-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try makeSourcePlugin(at: root, name: "unknown-plugin", pluginProtocol: "unknown")
    let installer = PluginPackageInstaller(
        pluginsRootURL: root.appendingPathComponent("plugins", isDirectory: true),
        cacheRootURL: root.appendingPathComponent("plugin-cache", isDirectory: true),
        processRunner: FakePluginProcessRunner()
    )

    #expect(throws: PluginPackageInstallError.self) {
        _ = try installer.validateSourcePackage(at: root)
    }
}

@Test
func taskSyncSourcePluginBuildsAndExpectsTaskSyncEntrypoint() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("plugin-loader-task-sync-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let pluginsRoot = root.appendingPathComponent("plugins", isDirectory: true)
    let source = pluginsRoot.appendingPathComponent("task-sync-plugin", isDirectory: true)
    try makeSourcePlugin(at: source, name: "task-sync-plugin", pluginProtocol: "task_sync")

    let runner = FakePluginProcessRunner()
    let loader = PluginLoader(processRunner: runner)
    let loaded = await loader.loadTaskSyncPluginBundles(
        from: pluginsRoot,
        cacheRootURL: root.appendingPathComponent("plugin-cache", isDirectory: true)
    )

    #expect(loaded.isEmpty)
    let commands = await runner.commands()
    #expect(commands.contains(where: { $0.executable == "swift" && $0.arguments == ["build", "-c", "release", "--product", "task-sync-plugin"] }))
}

@Test
func pluginLoaderSkipsDisabledSourcePluginBeforeBuild() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("plugin-loader-disabled-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let pluginsRoot = root.appendingPathComponent("plugins", isDirectory: true)
    let source = pluginsRoot.appendingPathComponent("disabled-plugin", isDirectory: true)
    try makeSourcePlugin(at: source, name: "disabled-plugin")

    let runner = FakePluginProcessRunner()
    let loader = PluginLoader(processRunner: runner)
    let loaded = await loader.loadGatewayPluginBundles(
        from: pluginsRoot,
        cacheRootURL: root.appendingPathComponent("plugin-cache", isDirectory: true),
        inboundReceiver: NoopInboundMessageReceiver(),
        disabledPluginIDs: ["disabled-plugin"]
    )

    #expect(loaded.isEmpty)
    #expect(await runner.commands().isEmpty)
}

@Test
func pluginLoaderSelectsNodejsRuntimeWithoutSwiftBuild() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("plugin-loader-node-runtime-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let pluginsRoot = root.appendingPathComponent("plugins", isDirectory: true)
    try makeNodePlugin(
        at: pluginsRoot.appendingPathComponent("node-tool", isDirectory: true),
        name: "node-tool",
        pluginProtocol: "tool",
        config: #""supportedTools": ["node.echo"]"#
    )
    try makeNodePlugin(
        at: pluginsRoot.appendingPathComponent("node-gateway", isDirectory: true),
        name: "node-gateway",
        pluginProtocol: "gateway",
        config: #""channelIds": ["main"]"#
    )

    let runner = FakePluginProcessRunner()
    let loader = PluginLoader(processRunner: runner)
    let tools = await loader.loadToolPluginBundles(
        from: pluginsRoot,
        cacheRootURL: root.appendingPathComponent("plugin-cache", isDirectory: true)
    )
    let gateways = await loader.loadGatewayPluginBundles(
        from: pluginsRoot,
        cacheRootURL: root.appendingPathComponent("plugin-cache", isDirectory: true),
        inboundReceiver: NoopInboundMessageReceiver()
    )

    #expect(tools.map(\.manifest.name) == ["node-tool"])
    #expect(tools.first?.plugin.supportedTools == ["node.echo"])
    #expect(gateways.map(\.manifest.name) == ["node-gateway"])
    #expect(gateways.first?.plugin.channelIds == ["main"])
    #expect(await runner.commands().filter { $0.executable == "swift" }.isEmpty)
}

private func makeSourcePlugin(
    at url: URL,
    name: String,
    pluginProtocol: String = "gateway"
) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let package = """
    // swift-tools-version: 6.2
    import PackageDescription

    let package = Package(
        name: "\(name)",
        products: [
            .library(name: "\(name)", type: .dynamic, targets: ["Plugin"])
        ],
        targets: [
            .target(name: "Plugin")
        ]
    )
    """
    let manifest = """
    {
      "name": "\(name)",
      "protocol": "\(pluginProtocol)",
      "version": "1.0.0"
    }
    """
    try Data(package.utf8).write(to: url.appendingPathComponent("Package.swift"))
    try Data(manifest.utf8).write(to: url.appendingPathComponent("plugin.json"))
}

private func makeNodePlugin(
    at url: URL,
    name: String,
    pluginProtocol: String,
    config: String = ""
) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let configLine = config.isEmpty ? "" : ",\n  \"config\": {\n    \(config)\n  }"
    let manifest = """
    {
      "name": "\(name)",
      "protocol": "\(pluginProtocol)",
      "version": "1.0.0",
      "runtime": "nodejs",
      "entrypoint": "index.js"\(configLine)
    }
    """
    let script = """
    #!/usr/bin/env node
    process.stdin.resume();
    process.stdin.on("data", () => {
      process.stdout.write(JSON.stringify({ result: {} }) + "\\n");
    });
    """
    try Data(manifest.utf8).write(to: url.appendingPathComponent("plugin.json"))
    try Data(script.utf8).write(to: url.appendingPathComponent("index.js"))
}

private struct NoopInboundMessageReceiver: InboundMessageReceiver {
    func postMessage(
        channelId: String,
        userId: String,
        content: String,
        topicId: String?,
        inboundContext: ChannelInboundContext?
    ) async -> Bool {
        true
    }
}
