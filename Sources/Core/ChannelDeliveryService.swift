import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Protocols

/// Delivers outbound channel messages to registered channel plugins via HTTP.
actor ChannelDeliveryService {
    private let store: any PersistenceStore
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

    /// Delivers a message to the plugin responsible for `channelId`, if any.
    /// Returns `true` when delivery was attempted and the plugin responded 2xx.
    @discardableResult
    func deliver(channelId: String, userId: String, content: String) async -> Bool {
        let plugins = await store.listChannelPlugins()
        guard let plugin = plugins.first(where: { $0.enabled && $0.channelIds.contains(channelId) }) else {
            return false
        }
        return await post(plugin: plugin, channelId: channelId, userId: userId, content: content)
    }

    private func post(plugin: ChannelPluginRecord, channelId: String, userId: String, content: String) async -> Bool {
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
