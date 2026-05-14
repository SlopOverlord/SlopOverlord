import Foundation
import Logging

struct PluginPackageBuildResult: Sendable {
    var binaryURL: URL
    var rebuilt: Bool
}

enum PluginPackageBuildError: Error, LocalizedError, Sendable {
    case swiftCommandFailed(command: String, exitCode: Int32, output: String)
    case artifactNotFound(plugin: String)
    case copyFailed(String)

    var errorDescription: String? {
        switch self {
        case .swiftCommandFailed(let command, let exitCode, let output):
            return "\(command) failed with exit \(exitCode). \(output)"
        case .artifactNotFound(let plugin):
            return "Build completed, but no dynamic library artifact was found for plugin \(plugin)."
        case .copyFailed(let message):
            return message
        }
    }
}

struct PluginPackageBuilder {
    private let cacheRootURL: URL
    private let processRunner: any PluginProcessRunning
    private let fileManager: FileManager
    private let logger: Logger

    init(
        cacheRootURL: URL,
        processRunner: any PluginProcessRunning = LivePluginProcessRunner(),
        fileManager: FileManager = .default,
        logger: Logger = Logger(label: "sloppy.plugin.builder")
    ) {
        self.cacheRootURL = cacheRootURL
        self.processRunner = processRunner
        self.fileManager = fileManager
        self.logger = logger
    }

    func buildGatewayPlugin(
        at packageURL: URL,
        manifest: PluginManifest
    ) async throws -> PluginPackageBuildResult {
        let fingerprint = await buildFingerprint(packageURL: packageURL, manifest: manifest)
        let cacheDirectory = cacheRootURL
            .appendingPathComponent(manifest.name, isDirectory: true)
            .appendingPathComponent(fingerprint, isDirectory: true)
        let cachedBinary = cacheDirectory.appendingPathComponent(defaultCachedBinaryName(for: manifest.name))
        if fileManager.fileExists(atPath: cachedBinary.path) {
            return PluginPackageBuildResult(binaryURL: cachedBinary, rebuilt: false)
        }

        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        let binPath = try await swiftBinPath(packageURL: packageURL)
        try await runSwiftBuild(packageURL: packageURL, product: manifest.name)

        guard let artifact = findDynamicLibrary(named: manifest.name, binPath: binPath, packageURL: packageURL) else {
            throw PluginPackageBuildError.artifactNotFound(plugin: manifest.name)
        }

        do {
            if fileManager.fileExists(atPath: cachedBinary.path) {
                try fileManager.removeItem(at: cachedBinary)
            }
            try fileManager.copyItem(at: artifact, to: cachedBinary)
        } catch {
            throw PluginPackageBuildError.copyFailed("Failed to cache plugin binary: \(error)")
        }

        logger.info("Built source plugin \(manifest.name) into \(cachedBinary.path).")
        return PluginPackageBuildResult(binaryURL: cachedBinary, rebuilt: true)
    }

    private func swiftBinPath(packageURL: URL) async throws -> URL {
        let result = try await processRunner.run(
            "swift",
            arguments: ["build", "--show-bin-path", "-c", "release"],
            cwd: packageURL
        )
        guard result.exitCode == 0 else {
            throw PluginPackageBuildError.swiftCommandFailed(
                command: "swift build --show-bin-path",
                exitCode: result.exitCode,
                output: combinedOutput(result)
            )
        }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func runSwiftBuild(packageURL: URL, product: String) async throws {
        let result = try await processRunner.run(
            "swift",
            arguments: ["build", "-c", "release", "--product", product],
            cwd: packageURL
        )
        guard result.exitCode == 0 else {
            throw PluginPackageBuildError.swiftCommandFailed(
                command: "swift build -c release --product \(product)",
                exitCode: result.exitCode,
                output: combinedOutput(result)
            )
        }
    }

    private func buildFingerprint(packageURL: URL, manifest: PluginManifest) async -> String {
        var parts: [String] = [
            "plugin=\(manifest.name)",
            "version=\(manifest.version ?? "")",
            "configuration=release",
            "os=\(Self.currentOS)",
            "arch=\(Self.currentArch)",
            "swift=\(await swiftVersion())",
            "git=\(await gitRevision(packageURL: packageURL))",
            "Package.swift=\(fileDigest(packageURL.appendingPathComponent("Package.swift")))",
            "Package.resolved=\(fileDigest(packageURL.appendingPathComponent("Package.resolved")))",
        ]
        parts.sort()
        return Self.fnv1a64(parts.joined(separator: "\n"))
    }

    private func swiftVersion() async -> String {
        guard let result = try? await processRunner.run("swift", arguments: ["--version"], cwd: nil),
              result.exitCode == 0
        else {
            return "unknown"
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func gitRevision(packageURL: URL) async -> String {
        guard let result = try? await processRunner.run(
            "git",
            arguments: ["rev-parse", "HEAD"],
            cwd: packageURL
        ),
            result.exitCode == 0
        else {
            return "nogit"
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fileDigest(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else {
            return "missing"
        }
        return Self.fnv1a64(String(decoding: data, as: UTF8.self))
    }

    private func findDynamicLibrary(named name: String, binPath: URL, packageURL: URL) -> URL? {
        let candidateNames = Self.dynamicLibraryCandidateNames(for: name)
        let directCandidates = candidateNames.map { binPath.appendingPathComponent($0) }
        if let found = directCandidates.first(where: { fileManager.fileExists(atPath: $0.path) }) {
            return found
        }

        let buildRoot = packageURL.appendingPathComponent(".build", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: buildRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let url as URL in enumerator {
            guard candidateNames.contains(url.lastPathComponent) else {
                continue
            }
            return url
        }
        return nil
    }

    private func defaultCachedBinaryName(for name: String) -> String {
        #if os(Linux)
        return "lib\(name).so"
        #else
        return "lib\(name).dylib"
        #endif
    }

    private func combinedOutput(_ result: PluginProcessResult) -> String {
        [result.stdout, result.stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func dynamicLibraryCandidateNames(for name: String) -> [String] {
        [
            "lib\(name).dylib",
            "\(name).dylib",
            "lib\(name).so",
            "\(name).so",
        ]
    }

    private static var currentOS: String {
        #if os(macOS)
        return "macos"
        #elseif os(Linux)
        return "linux"
        #else
        return "unknown"
        #endif
    }

    private static var currentArch: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static func fnv1a64(_ input: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
