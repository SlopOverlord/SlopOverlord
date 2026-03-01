import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Protocols
import PluginSDK

/// Delivers outbound channel messages to registered channel plugins.
/// Supports both in-process GatewayPlugin instances and out-of-process HTTP plugins.
actor ChannelDeliveryService {
    private let store: any PersistenceStore
    private var inProcessPlugins: [String: any GatewayPlugin] = [:]
#if canImport(FoundationNetworking)
    private let session: URLSession
#endif
    private let timeoutInterval: TimeInterval

    init(store: any PersistenceStore, timeoutInterval: TimeInterval = 10) {
        self.store = store
        self.timeoutInterval = timeoutInterval
#if canImport(FoundationNetworking)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeoutInterval
        self.session = URLSession(configuration: config)
#endif
    }

    /// Registers an in-process GatewayPlugin for its declared channel IDs.
    func registerPlugin(_ plugin: any GatewayPlugin) {
        for channelId in plugin.channelIds {
            inProcessPlugins[channelId] = plugin
        }
    }

    /// Removes the in-process plugin registration for all its channel IDs.
    func unregisterPlugin(_ plugin: any GatewayPlugin) {
        for channelId in plugin.channelIds {
            inProcessPlugins[channelId] = nil
        }
    }

    /// Delivers a message to the plugin responsible for `channelId`, if any.
    /// Prefers in-process delivery; falls back to HTTP for out-of-process plugins.
    /// Returns `true` when delivery was attempted successfully.
    @discardableResult
    func deliver(channelId: String, userId: String, content: String) async -> Bool {
        if let plugin = inProcessPlugins[channelId] {
            do {
                try await plugin.send(channelId: channelId, message: content)
                return true
            } catch {
                return false
            }
        }

        let plugins = await store.listChannelPlugins()
        guard let plugin = plugins.first(where: {
            $0.enabled
            && $0.deliveryMode != ChannelPluginRecord.DeliveryMode.inProcess
            && $0.channelIds.contains(channelId)
        }) else {
            return false
        }
        return await postHTTP(plugin: plugin, channelId: channelId, userId: userId, content: content)
    }

    private func postHTTP(
        plugin: ChannelPluginRecord,
        channelId: String,
        userId: String,
        content: String
    ) async -> Bool {
#if canImport(FoundationNetworking)
        let urlString = plugin.baseUrl.hasSuffix("/")
            ? "\(plugin.baseUrl)deliver"
            : "\(plugin.baseUrl)/deliver"

        guard let url = URL(string: urlString) else {
            return false
        }

        let body = ChannelPluginDeliverRequest(channelId: channelId, userId: userId, content: content)
        guard let bodyData = try? JSONEncoder().encode(body) else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        request.timeoutInterval = timeoutInterval

        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                return (200..<300).contains(http.statusCode)
            }
            return false
        } catch {
            return false
        }
#else
        return false
#endif
    }
}
