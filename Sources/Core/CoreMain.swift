import ArgumentParser
import Configuration
import Foundation
import Logging
import Protocols
#if os(Linux)
import Glibc
#else
import Darwin
#endif

@main
struct CoreMain: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "slopoverlord-core",
        abstract: "Starts SlopOverlord core runtime demo entrypoint."
    )

    @Option(name: [.short, .long], help: "Path to JSON config file")
    var configPath: String?

    @Flag(name: .long, inversion: .prefixedNo, help: "Generates an immediate visor bulletin after boot")
    var bootstrapBulletin: Bool = true

    @Flag(name: .long, help: "Runs demo request on startup")
    var runDemoRequest: Bool = false

    @Flag(name: .long, help: "Run one-shot startup flow and exit")
    var oneshot: Bool = false

    mutating func run() async throws {
        var runtimeLogger: Logger?

        do {
            var explicitConfigPath = normalizedConfigPath(configPath)
            var config = CoreConfig.load(from: explicitConfigPath)

            if #available(macOS 15.0, *) {
                let envConfig = ConfigReader(providers: [EnvironmentVariablesProvider()])
                if let envConfigPath = normalizedConfigPath(
                    envConfig.string(forKey: "core.config.path", default: "")
                ) {
                    explicitConfigPath = envConfigPath
                    config = CoreConfig.load(from: explicitConfigPath)
                }

                applyEnvironmentOverrides(config: &config, envConfig: envConfig)

                if explicitConfigPath == nil {
                    let workspaceConfigPath = CoreConfig.defaultConfigPath(for: config.workspace)
                    if FileManager.default.fileExists(atPath: workspaceConfigPath) {
                        config = CoreConfig.load(from: workspaceConfigPath)
                        applyEnvironmentOverrides(config: &config, envConfig: envConfig)
                    }
                }
            } else if explicitConfigPath == nil {
                let workspaceConfigPath = CoreConfig.defaultConfigPath(for: config.workspace)
                if FileManager.default.fileExists(atPath: workspaceConfigPath) {
                    config = CoreConfig.load(from: workspaceConfigPath)
                }
            }

            let workspaceRoot = try prepareWorkspace(config: &config)
            let systemLogFileURL = defaultSystemLogFileURL(in: workspaceRoot)
            await LoggingBootstrapper.shared.bootstrapIfNeeded(logFileURL: systemLogFileURL)
            let logger = Logger(label: "slopoverlord.core.main")
            runtimeLogger = logger
            await FatalSignalLogger.shared.installIfNeeded()
            logger.info("Workspace prepared at \(workspaceRoot.path)")
            logger.info("System logs are persisted at \(systemLogFileURL.path)")

            let resolvedConfigPath = explicitConfigPath ??
                workspaceRoot.appendingPathComponent(CoreConfig.defaultConfigFileName).path
            try ensureConfigFileExists(path: resolvedConfigPath, config: config, logger: logger)
            let service = CoreService(config: config, configPath: resolvedConfigPath)
            let router = CoreRouter(service: service)
            let server = CoreHTTPServer(
                host: config.listen.host,
                port: config.listen.port,
                router: router,
                logger: logger
            )

            logger.info("SlopOverlord Core initialized")

            if !oneshot {
                try server.start()
                logger.info("Core HTTP server listening on \(config.listen.host):\(config.listen.port)")
            }

            if runDemoRequest {
                let sampleRequest = ChannelMessageRequest(
                    userId: "demo-user",
                    content: "Implement a feature and run tests"
                )
                let requestBody = try? JSONEncoder().encode(sampleRequest)
                let response = await router.handle(
                    method: "POST",
                    path: "/v1/channels/general/messages",
                    body: requestBody
                )

                if let body = String(data: response.body, encoding: .utf8) {
                    logger.info("POST /v1/channels/general/messages -> \(response.status) \(body)")
                }
            }

            if bootstrapBulletin {
                let bulletin = await service.triggerVisorBulletin()
                logger.info("Visor bulletin generated: \(bulletin.headline)")
            }

            // Foreground server mode by default: keep process alive for container/service runtime.
            if !oneshot {
                logger.info("SlopOverlord Core foreground server mode is active")
                defer { try? server.shutdown() }
                try server.waitUntilClosed()
            }
        } catch {
            if let runtimeLogger {
                runtimeLogger.critical("Core is exiting because of an unrecoverable error: \(String(describing: error))")
            } else {
                emitBootstrapWarning("Core is exiting because of an unrecoverable error: \(String(describing: error))")
            }
            throw error
        }
    }
}

@available(macOS 15.0, *)
private func applyEnvironmentOverrides(config: inout CoreConfig, envConfig: ConfigReader) {
    config.listen.host = envConfig.string(forKey: "core.listen.host", default: config.listen.host)
    config.listen.port = envConfig.int(forKey: "core.listen.port", default: config.listen.port)
    config.workspace.name = envConfig.string(forKey: "core.workspace.name", default: config.workspace.name)
    let workspaceBasePath = envConfig.string(
        forKey: "core.workspace.base_path",
        default: config.workspace.basePath
    )
    config.workspace.basePath = envConfig.string(
        forKey: "core.workspace.basePath",
        default: workspaceBasePath
    )
    config.auth.token = envConfig.string(forKey: "core.auth.token", default: config.auth.token)
    config.sqlitePath = envConfig.string(forKey: "core.sqlite.path", default: config.sqlitePath)
}

private func normalizedConfigPath(_ raw: String?) -> String? {
    guard let raw else {
        return nil
    }

    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        return nil
    }
    return trimmed
}

private func ensureConfigFileExists(path: String, config: CoreConfig, logger: Logger) throws {
    let fileManager = FileManager.default
    let configURL = URL(fileURLWithPath: path)
    if fileManager.fileExists(atPath: configURL.path) {
        return
    }

    let parentDirectory = configURL.deletingLastPathComponent()
    try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let payload = try encoder.encode(config) + Data("\n".utf8)
    try payload.write(to: configURL, options: .atomic)
    logger.info("Config initialized at \(configURL.path)")
}

private func prepareWorkspace(config: inout CoreConfig) throws -> URL {
    let workspaceRoot = config.resolvedWorkspaceRootURL()

    do {
        try createWorkspaceDirectories(at: workspaceRoot)
        config.sqlitePath = resolveSQLitePath(sqlitePath: config.sqlitePath, workspaceRoot: workspaceRoot)
        return workspaceRoot
    } catch {
        let fallbackBasePath = "/tmp/slopoverlord"
        let fallbackRoot = URL(fileURLWithPath: fallbackBasePath, isDirectory: true)
            .appendingPathComponent(config.workspace.name, isDirectory: true)

        emitBootstrapWarning(
            "Failed to create workspace at \(workspaceRoot.path), falling back to \(fallbackRoot.path): \(error)"
        )

        try createWorkspaceDirectories(at: fallbackRoot)
        config.workspace.basePath = fallbackBasePath
        config.sqlitePath = resolveSQLitePath(sqlitePath: config.sqlitePath, workspaceRoot: fallbackRoot)
        return fallbackRoot
    }
}

private func createWorkspaceDirectories(at workspaceRoot: URL) throws {
    let fileManager = FileManager.default
    let directories = [
        workspaceRoot,
        workspaceRoot.appendingPathComponent("agents", isDirectory: true),
        workspaceRoot.appendingPathComponent("sessions", isDirectory: true),
        workspaceRoot.appendingPathComponent("artifacts", isDirectory: true),
        workspaceRoot.appendingPathComponent("memory", isDirectory: true),
        workspaceRoot.appendingPathComponent("logs", isDirectory: true),
        workspaceRoot.appendingPathComponent("tmp", isDirectory: true)
    ]

    for directory in directories {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}

private func resolveSQLitePath(sqlitePath: String, workspaceRoot: URL) -> String {
    if sqlitePath.hasPrefix("/") {
        return sqlitePath
    }
    return workspaceRoot.appendingPathComponent(sqlitePath).path
}

private func defaultSystemLogFileURL(in workspaceRoot: URL, now: Date = Date()) -> URL {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    let suffix = formatter.string(from: now)
    return workspaceRoot
        .appendingPathComponent("logs", isDirectory: true)
        .appendingPathComponent("core-\(suffix).log")
}

private func emitBootstrapWarning(_ message: String) {
    let payload = "[warning] \(message)\n"
    payload.withCString { pointer in
        _ = write(STDERR_FILENO, pointer, strlen(pointer))
    }
}

private actor LoggingBootstrapper {
    static let shared = LoggingBootstrapper()

    private var isBootstrapped = false

    func bootstrapIfNeeded(logFileURL: URL) {
        guard !isBootstrapped else {
            return
        }

        SystemJSONLLogHandler.configure(fileURL: logFileURL)
        LoggingSystem.bootstrap { label in
            MultiplexLogHandler([
                StreamLogHandler.standardError(label: label),
                SystemJSONLLogHandler(label: label)
            ])
        }
        isBootstrapped = true
    }
}

private actor FatalSignalLogger {
    static let shared = FatalSignalLogger()

    private var isInstalled = false
    private let trackedSignals: [Int32] = [SIGABRT, SIGILL, SIGTRAP, SIGSEGV, SIGBUS, SIGFPE]

    func installIfNeeded() {
        guard !isInstalled else {
            return
        }
        isInstalled = true

        for code in trackedSignals {
            _ = signal(code, coreFatalSignalHandler)
        }
    }
}

private func coreFatalSignalHandler(_ signalCode: Int32) {
    let signalName = signalNameForCode(signalCode)
    let text = "slopoverlord-core fatal signal \(signalCode) (\(signalName)). Process will exit.\n"
    text.withCString { pointer in
        _ = write(STDERR_FILENO, pointer, strlen(pointer))
    }

    _ = signal(signalCode, SIG_DFL)
    _ = raise(signalCode)
}

private func signalNameForCode(_ code: Int32) -> String {
    switch code {
    case SIGABRT: return "SIGABRT"
    case SIGILL: return "SIGILL"
    case SIGTRAP: return "SIGTRAP"
    case SIGSEGV: return "SIGSEGV"
    case SIGBUS: return "SIGBUS"
    case SIGFPE: return "SIGFPE"
    default: return "UNKNOWN"
    }
}
