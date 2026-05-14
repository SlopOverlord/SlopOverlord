import Foundation
import Logging
import PluginSDK

/// Meta-information parsed from a plugin's `plugin.json` file.
public struct PluginManifest: Codable, Sendable {
    /// Unique plugin identifier (e.g. `"telegram"`).
    public var name: String
    /// Protocol the plugin implements: `"gateway"`, `"tool"`, `"memory"`, `"model_provider"`.
    public var `protocol`: String
    /// Optional semver string for display and diagnostics.
    public var version: String?
}

/// Scans a plugins directory and loads external GatewayPlugins via dlopen.
/// Bundled plugins (e.g. Telegram) are created directly by CoreService and do NOT go through this loader.
public struct PluginLoader: Sendable {
    private let logger: Logger
    private let processRunner: any PluginProcessRunning

    init(
        logger: Logger = Logger(label: "sloppy.plugin.loader"),
        processRunner: any PluginProcessRunning = LivePluginProcessRunner()
    ) {
        self.logger = logger
        self.processRunner = processRunner
    }

    /// Reads a `plugin.json` manifest from the given plugin directory.
    public func loadManifest(at pluginDirectory: URL) -> PluginManifest? {
        let manifestURL = pluginDirectory.appendingPathComponent("plugin.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            return nil
        }
        return try? JSONDecoder().decode(PluginManifest.self, from: data)
    }

    /// Loads all external gateway plugins found under `pluginsDirectory`.
    /// Each sub-directory must contain a `plugin.json` and either a prebuilt binary or a SwiftPM package.
    /// Returns only successfully loaded plugins; logs failures and continues.
    public func loadGatewayPlugins(
        from pluginsDirectory: URL,
        inboundReceiver: any InboundMessageReceiver
    ) async -> [any GatewayPlugin] {
        let cacheRootURL = pluginsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("plugin-cache", isDirectory: true)
        let loaded = await loadGatewayPluginBundles(
            from: pluginsDirectory,
            cacheRootURL: cacheRootURL,
            inboundReceiver: inboundReceiver
        )
        return loaded.map(\.plugin)
    }

    func loadGatewayPluginBundles(
        from pluginsDirectory: URL,
        cacheRootURL: URL,
        inboundReceiver: any InboundMessageReceiver,
        disabledPluginIDs: Set<String> = []
    ) async -> [LoadedGatewayPlugin] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: pluginsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var plugins: [LoadedGatewayPlugin] = []

        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                continue
            }

            guard let manifest = loadManifest(at: entry) else {
                logger.warning("No valid plugin.json in \(entry.lastPathComponent), skipping.")
                continue
            }

            guard manifest.protocol == "gateway" else {
                logger.debug("Plugin \(manifest.name) is not a gateway plugin, skipping for now.")
                continue
            }

            if disabledPluginIDs.contains(manifest.name) {
                logger.info("Plugin \(manifest.name) is disabled, skipping.")
                continue
            }

            if let plugin = await loadGatewayPlugin(
                from: entry,
                cacheRootURL: cacheRootURL,
                manifest: manifest,
                inboundReceiver: inboundReceiver
            ) {
                plugins.append(plugin)
            }
        }

        return plugins
    }

    func loadGatewayPlugin(
        from directory: URL,
        cacheRootURL: URL,
        manifest: PluginManifest,
        inboundReceiver: any InboundMessageReceiver
    ) async -> LoadedGatewayPlugin? {
        let fileManager = FileManager.default
        let binaryURL: URL
        let rebuilt: Bool

        if fileManager.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) {
            do {
                let builder = PluginPackageBuilder(
                    cacheRootURL: cacheRootURL,
                    processRunner: processRunner,
                    fileManager: fileManager,
                    logger: Logger(label: "sloppy.plugin.builder")
                )
                let build = try await builder.buildGatewayPlugin(at: directory, manifest: manifest)
                binaryURL = build.binaryURL
                rebuilt = build.rebuilt
            } catch {
                logger.error("Failed to build source plugin \(manifest.name): \(error)")
                return nil
            }
        } else {
            guard let found = findBinary(in: directory, name: manifest.name) else {
                logger.warning("No dynamic library binary found for plugin \(manifest.name) in \(directory.lastPathComponent).")
                return nil
            }
            binaryURL = found
            rebuilt = false
        }

        guard let plugin = loadDylibGatewayPlugin(
            binaryURL: binaryURL,
            manifest: manifest,
            inboundReceiver: inboundReceiver
        ) else {
            return nil
        }
        return LoadedGatewayPlugin(
            manifest: manifest,
            plugin: plugin,
            sourceURL: directory,
            binaryURL: binaryURL,
            rebuilt: rebuilt
        )
    }

    // MARK: - dlopen

    func loadDylibGatewayPlugin(
        binaryURL: URL,
        manifest: PluginManifest,
        inboundReceiver: any InboundMessageReceiver
    ) -> (any GatewayPlugin)? {
        guard let handle = dlopen(binaryURL.path, RTLD_NOW | RTLD_LOCAL) else {
            let error = String(cString: dlerror())
            logger.error("dlopen failed for plugin \(manifest.name): \(error)")
            return nil
        }

        guard let sym = dlsym(handle, "sloppy_gateway_create") else {
            let error = String(cString: dlerror())
            logger.error("dlsym(sloppy_gateway_create) failed for plugin \(manifest.name): \(error)")
            dlclose(handle)
            return nil
        }

        // C ABI: void* sloppy_gateway_create(const char* manifest_json, void* inbound_receiver_opaque)
        // The opaque pointer is an Unmanaged reference to the InboundMessageReceiver existential box.
        typealias CreateFn = @convention(c) (
            UnsafePointer<CChar>,
            UnsafeMutableRawPointer
        ) -> UnsafeMutableRawPointer?

        let createFn = unsafeBitCast(sym, to: CreateFn.self)

        let manifestJSON = (try? String(data: JSONEncoder().encode(manifest), encoding: .utf8)) ?? "{}"
        let receiverBox = GatewayPluginReceiverBox(receiver: inboundReceiver)
        let boxPtr = Unmanaged.passRetained(receiverBox).toOpaque()

        guard let rawPlugin = manifestJSON.withCString({ createFn($0, boxPtr) }) else {
            logger.error("sloppy_gateway_create returned nil for plugin \(manifest.name).")
            Unmanaged<GatewayPluginReceiverBox>.fromOpaque(boxPtr).release()
            dlclose(handle)
            return nil
        }

        let plugin = Unmanaged<AnyGatewayPluginBox>.fromOpaque(rawPlugin).takeRetainedValue()
        guard plugin.id == manifest.name else {
            logger.error("Plugin id mismatch for \(manifest.name): dylib returned \(plugin.id).")
            Unmanaged<GatewayPluginReceiverBox>.fromOpaque(boxPtr).release()
            dlclose(handle)
            return nil
        }
        logger.info("Loaded external gateway plugin \(manifest.name) v\(manifest.version ?? "unknown").")
        return plugin
    }

    private func findBinary(in directory: URL, name: String) -> URL? {
        let candidates = [
            directory.appendingPathComponent("plugin.dylib"),
            directory.appendingPathComponent("\(name).dylib"),
            directory.appendingPathComponent("lib\(name).dylib"),
            directory.appendingPathComponent("plugin.so"),
            directory.appendingPathComponent("\(name).so"),
            directory.appendingPathComponent("lib\(name).so"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

struct LoadedGatewayPlugin: Sendable {
    var manifest: PluginManifest
    var plugin: any GatewayPlugin
    var sourceURL: URL
    var binaryURL: URL
    var rebuilt: Bool
}
