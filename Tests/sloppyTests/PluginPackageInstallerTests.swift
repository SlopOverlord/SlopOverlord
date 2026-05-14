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
            try Data("binary".utf8).write(to: artifact)
            return PluginProcessResult(exitCode: 0, stdout: "", stderr: "")
        }

        return PluginProcessResult(exitCode: 0, stdout: "", stderr: "")
    }

    func commands() -> [(executable: String, arguments: [String], cwd: String?)] {
        recordedCommands
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
    #expect(FileManager.default.fileExists(atPath: first.binaryURL.path))

    let commandsAfterFirst = await runner.commands()
    #expect(commandsAfterFirst.contains(where: { $0.executable == "git" && $0.arguments.first == "clone" }))
    #expect(commandsAfterFirst.filter { $0.executable == "swift" && $0.arguments.contains("--product") }.count == 1)

    let second = try await installer.install(
        ChannelPluginInstallRequest(sourceUrl: source.path, force: true)
    )
    #expect(second.rebuilt == false)
    #expect(second.binaryURL.path == first.binaryURL.path)

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
func sourcePluginInstallerValidatesManifestProtocol() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("plugin-validation-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try makeSourcePlugin(at: root, name: "tool-plugin", pluginProtocol: "tool")
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
