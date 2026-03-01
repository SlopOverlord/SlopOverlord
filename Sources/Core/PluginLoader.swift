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

    public init(logger: Logger = Logger(label: "slopoverlord.plugin.loader")) {
        self.logger = logger
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
    /// Each sub-directory must contain a `plugin.json` and a `.dylib` binary.
    /// Returns only successfully loaded plugins; logs failures and continues.
    public func loadGatewayPlugins(
        from pluginsDirectory: URL,
        inboundReceiver: any InboundMessageReceiver
    ) async -> [any GatewayPlugin] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: pluginsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var plugins: [any GatewayPlugin] = []

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

            if let plugin = loadDylibGatewayPlugin(
                from: entry,
                manifest: manifest,
                inboundReceiver: inboundReceiver
            ) {
                plugins.append(plugin)
            }
        }

        return plugins
    }

    // MARK: - dlopen

    private func loadDylibGatewayPlugin(
        from directory: URL,
        manifest: PluginManifest,
        inboundReceiver: any InboundMessageReceiver
    ) -> (any GatewayPlugin)? {
        let binaryURL = findBinary(in: directory, name: manifest.name)
        guard let binaryURL else {
            logger.warning("No .dylib binary found for plugin \(manifest.name) in \(directory.lastPathComponent).")
            return nil
        }

        guard let handle = dlopen(binaryURL.path, RTLD_NOW | RTLD_LOCAL) else {
            let error = String(cString: dlerror())
            logger.error("dlopen failed for plugin \(manifest.name): \(error)")
            return nil
        }

        guard let sym = dlsym(handle, "slopoverlord_gateway_create") else {
            let error = String(cString: dlerror())
            logger.error("dlsym(slopoverlord_gateway_create) failed for plugin \(manifest.name): \(error)")
            dlclose(handle)
            return nil
        }

        // C ABI: void* slopoverlord_gateway_create(const char* manifest_json, void* inbound_receiver_opaque)
        // The opaque pointer is an Unmanaged reference to the InboundMessageReceiver existential box.
        typealias CreateFn = @convention(c) (
            UnsafePointer<CChar>,
            UnsafeMutableRawPointer
        ) -> UnsafeMutableRawPointer?

        let createFn = unsafeBitCast(sym, to: CreateFn.self)

        let manifestJSON = (try? String(data: JSONEncoder().encode(manifest), encoding: .utf8)) ?? "{}"
        let receiverBox = ReceiverBox(receiver: inboundReceiver)
        let boxPtr = Unmanaged.passRetained(receiverBox).toOpaque()

        guard let rawPlugin = manifestJSON.withCString({ createFn($0, boxPtr) }) else {
            logger.error("slopoverlord_gateway_create returned nil for plugin \(manifest.name).")
            Unmanaged<ReceiverBox>.fromOpaque(boxPtr).release()
            dlclose(handle)
            return nil
        }

        let plugin = Unmanaged<AnyGatewayPluginBox>.fromOpaque(rawPlugin).takeRetainedValue()
        logger.info("Loaded external gateway plugin \(manifest.name) v\(manifest.version ?? "unknown").")
        return plugin
    }

    private func findBinary(in directory: URL, name: String) -> URL? {
        let candidates = [
            directory.appendingPathComponent("plugin.dylib"),
            directory.appendingPathComponent("\(name).dylib")
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

// MARK: - Support types for dlopen ABI

/// Retains an InboundMessageReceiver to pass across the C ABI boundary.
final class ReceiverBox: @unchecked Sendable {
    let receiver: any InboundMessageReceiver
    init(receiver: any InboundMessageReceiver) { self.receiver = receiver }
}

/// Wraps an opaque GatewayPlugin returned by dlopen plugins.
final class AnyGatewayPluginBox: GatewayPlugin, @unchecked Sendable {
    let id: String
    let channelIds: [String]
    private let _start: @Sendable (any InboundMessageReceiver) async throws -> Void
    private let _stop: @Sendable () async -> Void
    private let _send: @Sendable (String, String) async throws -> Void

    init(
        id: String,
        channelIds: [String],
        start: @escaping @Sendable (any InboundMessageReceiver) async throws -> Void,
        stop: @escaping @Sendable () async -> Void,
        send: @escaping @Sendable (String, String) async throws -> Void
    ) {
        self.id = id
        self.channelIds = channelIds
        self._start = start
        self._stop = stop
        self._send = send
    }

    func start(inboundReceiver: any InboundMessageReceiver) async throws {
        try await _start(inboundReceiver)
    }

    func stop() async {
        await _stop()
    }

    func send(channelId: String, message: String) async throws {
        try await _send(channelId, message)
    }
}
