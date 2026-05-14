import Foundation
import Logging
import Protocols

struct PluginPackageInstallResult: Sendable {
    var manifest: PluginManifest
    var sourceURL: URL
    var binaryURL: URL
    var rebuilt: Bool
}

enum PluginPackageInstallError: Error, LocalizedError, Sendable {
    case invalidSourceURL
    case gitCommandFailed(command: String, exitCode: Int32, output: String)
    case missingPackageSwift
    case missingOrInvalidManifest
    case unsupportedProtocol(String)
    case invalidPluginName(String)
    case conflict(String)
    case moveFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidSourceURL:
            return "Plugin source URL is required."
        case .gitCommandFailed(let command, let exitCode, let output):
            return "\(command) failed with exit \(exitCode). \(output)"
        case .missingPackageSwift:
            return "Plugin package must contain Package.swift at its root."
        case .missingOrInvalidManifest:
            return "Plugin package must contain a valid plugin.json at its root."
        case .unsupportedProtocol(let value):
            return "Only gateway source plugins are supported in v1; plugin.json protocol was \(value)."
        case .invalidPluginName(let name):
            return "Invalid plugin name in plugin.json: \(name)."
        case .conflict(let name):
            return "Plugin \(name) already exists. Pass force=true to replace it."
        case .moveFailed(let message):
            return message
        }
    }
}

struct PluginPackageInstaller {
    private let pluginsRootURL: URL
    private let cacheRootURL: URL
    private let processRunner: any PluginProcessRunning
    private let fileManager: FileManager
    private let logger: Logger

    init(
        pluginsRootURL: URL,
        cacheRootURL: URL,
        processRunner: any PluginProcessRunning = LivePluginProcessRunner(),
        fileManager: FileManager = .default,
        logger: Logger = Logger(label: "sloppy.plugin.installer")
    ) {
        self.pluginsRootURL = pluginsRootURL
        self.cacheRootURL = cacheRootURL
        self.processRunner = processRunner
        self.fileManager = fileManager
        self.logger = logger
    }

    func install(_ request: ChannelPluginInstallRequest) async throws -> PluginPackageInstallResult {
        let source = request.sourceUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else {
            throw PluginPackageInstallError.invalidSourceURL
        }

        try fileManager.createDirectory(at: pluginsRootURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: cacheRootURL, withIntermediateDirectories: true)

        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "sloppy-plugin-install-\(UUID().uuidString)",
            isDirectory: true
        )
        let checkoutURL = tempRoot.appendingPathComponent("checkout", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        try await runGitClone(source: source, checkoutURL: checkoutURL)
        if let ref = request.ref?.trimmingCharacters(in: .whitespacesAndNewlines), !ref.isEmpty {
            try await runGitCheckout(ref: ref, checkoutURL: checkoutURL)
        }

        let manifest = try validateSourcePackage(at: checkoutURL)
        let targetURL = pluginsRootURL.appendingPathComponent(manifest.name, isDirectory: true)
        let force = request.force ?? false

        if fileManager.fileExists(atPath: targetURL.path) {
            guard force else {
                throw PluginPackageInstallError.conflict(manifest.name)
            }
            try fileManager.removeItem(at: targetURL)
        }

        do {
            try fileManager.moveItem(at: checkoutURL, to: targetURL)
        } catch {
            throw PluginPackageInstallError.moveFailed("Failed to move plugin source into workspace: \(error)")
        }

        let builder = PluginPackageBuilder(
            cacheRootURL: cacheRootURL,
            processRunner: processRunner,
            fileManager: fileManager,
            logger: Logger(label: "sloppy.plugin.builder")
        )
        let build = try await builder.buildGatewayPlugin(at: targetURL, manifest: manifest)
        logger.info("Installed source plugin \(manifest.name) from \(source).")
        return PluginPackageInstallResult(
            manifest: manifest,
            sourceURL: targetURL,
            binaryURL: build.binaryURL,
            rebuilt: build.rebuilt
        )
    }

    func validateSourcePackage(at packageURL: URL) throws -> PluginManifest {
        guard fileManager.fileExists(atPath: packageURL.appendingPathComponent("Package.swift").path) else {
            throw PluginPackageInstallError.missingPackageSwift
        }
        let manifestURL = packageURL.appendingPathComponent("plugin.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(PluginManifest.self, from: data)
        else {
            throw PluginPackageInstallError.missingOrInvalidManifest
        }
        guard manifest.protocol == "gateway" else {
            throw PluginPackageInstallError.unsupportedProtocol(manifest.protocol)
        }
        guard isValidPluginDirectoryName(manifest.name) else {
            throw PluginPackageInstallError.invalidPluginName(manifest.name)
        }
        return manifest
    }

    private func runGitClone(source: String, checkoutURL: URL) async throws {
        let result = try await processRunner.run(
            "git",
            arguments: ["clone", source, checkoutURL.path],
            cwd: nil
        )
        guard result.exitCode == 0 else {
            throw PluginPackageInstallError.gitCommandFailed(
                command: "git clone",
                exitCode: result.exitCode,
                output: combinedOutput(result)
            )
        }
    }

    private func runGitCheckout(ref: String, checkoutURL: URL) async throws {
        let result = try await processRunner.run(
            "git",
            arguments: ["checkout", ref],
            cwd: checkoutURL
        )
        guard result.exitCode == 0 else {
            throw PluginPackageInstallError.gitCommandFailed(
                command: "git checkout \(ref)",
                exitCode: result.exitCode,
                output: combinedOutput(result)
            )
        }
    }

    private func isValidPluginDirectoryName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed == name,
              trimmed == trimmed.lowercased(),
              trimmed.count <= 128,
              !trimmed.contains("/")
        else {
            return false
        }
        return trimmed.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
    }

    private func combinedOutput(_ result: PluginProcessResult) -> String {
        [result.stdout, result.stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
