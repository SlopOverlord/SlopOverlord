import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Protocols
import PluginSDK

/// Delivers outbound channel messages to registered channel plugins.
/// Supports both in-process GatewayPlugin instances and out-of-process HTTP plugins.
actor ChannelDeliveryService {
    private struct ActiveStream: Sendable {
        enum Transport: Sendable {
            case inProcess(plugin: any StreamingGatewayPlugin, handle: GatewayOutboundStreamHandle)
            case http(plugin: ChannelPluginRecord, remoteStreamId: String)
        }

        let channelId: String
        let userId: String
        let transport: Transport
        var latestContent: String
    }

    private var store: any PersistenceStore
    private var inProcessPlugins: [String: any GatewayPlugin] = [:]
    private var activeStreams: [UUID: ActiveStream] = [:]
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

    func updateStore(_ store: any PersistenceStore) {
        self.store = store
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

    func beginStream(channelId: String, userId: String) async -> UUID? {
        if let plugin = inProcessPlugins[channelId] as? any StreamingGatewayPlugin {
            do {
                let handle = try await plugin.beginStreaming(channelId: channelId, userId: userId)
                let streamID = UUID()
                activeStreams[streamID] = ActiveStream(
                    channelId: channelId,
                    userId: userId,
                    transport: .inProcess(plugin: plugin, handle: handle),
                    latestContent: ""
                )
                return streamID
            } catch {
                return nil
            }
        }

        guard let plugin = await externalPlugin(for: channelId),
              let remoteStreamId = await startHTTPStream(plugin: plugin, channelId: channelId, userId: userId)
        else {
            return nil
        }

        let streamID = UUID()
        activeStreams[streamID] = ActiveStream(
            channelId: channelId,
            userId: userId,
            transport: .http(plugin: plugin, remoteStreamId: remoteStreamId),
            latestContent: ""
        )
        return streamID
    }

    @discardableResult
    func updateStream(id: UUID, content: String) async -> Bool {
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              var stream = activeStreams[id]
        else {
            return false
        }

        let success: Bool
        switch stream.transport {
        case .inProcess(let plugin, let handle):
            do {
                try await plugin.updateStreaming(handle: handle, channelId: stream.channelId, content: normalized)
                success = true
            } catch {
                success = false
            }
        case .http(let plugin, let remoteStreamId):
            success = await sendHTTPStreamChunk(
                plugin: plugin,
                request: ChannelPluginStreamChunkRequest(
                    streamId: remoteStreamId,
                    channelId: stream.channelId,
                    content: normalized
                )
            )
        }

        if success {
            stream.latestContent = normalized
            activeStreams[id] = stream
        }
        return success
    }

    @discardableResult
    func endStream(id: UUID, finalContent: String?) async -> Bool {
        guard let stream = activeStreams.removeValue(forKey: id) else {
            return false
        }

        let trimmedFinal = finalContent?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFinal = (trimmedFinal?.isEmpty == false) ? trimmedFinal : nil

        let success: Bool
        switch stream.transport {
        case .inProcess(let plugin, let handle):
            do {
                try await plugin.endStreaming(
                    handle: handle,
                    channelId: stream.channelId,
                    userId: stream.userId,
                    finalContent: normalizedFinal
                )
                success = true
            } catch {
                success = false
            }
        case .http(let plugin, let remoteStreamId):
            success = await endHTTPStream(
                plugin: plugin,
                request: ChannelPluginStreamEndRequest(
                    streamId: remoteStreamId,
                    channelId: stream.channelId,
                    userId: stream.userId,
                    content: normalizedFinal
                )
            )
        }

        if success {
            return true
        }

        guard let normalizedFinal,
              stream.latestContent.isEmpty
        else {
            return false
        }

        return await deliver(channelId: stream.channelId, userId: stream.userId, content: normalizedFinal)
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

        guard let plugin = await externalPlugin(for: channelId) else {
            return false
        }
        return await postHTTP(plugin: plugin, channelId: channelId, userId: userId, content: content)
    }

    private func externalPlugin(for channelId: String) async -> ChannelPluginRecord? {
        let plugins = await store.listChannelPlugins()
        return plugins.first(where: {
            $0.enabled
            && $0.deliveryMode != ChannelPluginRecord.DeliveryMode.inProcess
            && $0.channelIds.contains(channelId)
        })
    }

    private func postHTTP(
        plugin: ChannelPluginRecord,
        channelId: String,
        userId: String,
        content: String
    ) async -> Bool {
#if canImport(FoundationNetworking)
        let body = ChannelPluginDeliverRequest(channelId: channelId, userId: userId, content: content)
        guard let bodyData = try? JSONEncoder().encode(body),
              let response = await sendPluginRequest(plugin: plugin, path: "deliver", bodyData: bodyData)
        else {
            return false
        }
        return (200..<300).contains(response.statusCode)
#else
        return false
#endif
    }

    private func startHTTPStream(
        plugin: ChannelPluginRecord,
        channelId: String,
        userId: String
    ) async -> String? {
#if canImport(FoundationNetworking)
        let body = ChannelPluginStreamStartRequest(channelId: channelId, userId: userId)
        guard let bodyData = try? JSONEncoder().encode(body),
              let response = await sendPluginRequest(plugin: plugin, path: "stream/start", bodyData: bodyData),
              (200..<300).contains(response.statusCode),
              let decoded = try? JSONDecoder().decode(ChannelPluginStreamStartResponse.self, from: response.data),
              decoded.ok,
              let streamId = decoded.streamId,
              !streamId.isEmpty
        else {
            return nil
        }
        return streamId
#else
        return nil
#endif
    }

    private func sendHTTPStreamChunk(
        plugin: ChannelPluginRecord,
        request: ChannelPluginStreamChunkRequest
    ) async -> Bool {
#if canImport(FoundationNetworking)
        guard let bodyData = try? JSONEncoder().encode(request),
              let response = await sendPluginRequest(plugin: plugin, path: "stream/chunk", bodyData: bodyData)
        else {
            return false
        }
        return (200..<300).contains(response.statusCode)
#else
        return false
#endif
    }

    private func endHTTPStream(
        plugin: ChannelPluginRecord,
        request: ChannelPluginStreamEndRequest
    ) async -> Bool {
#if canImport(FoundationNetworking)
        guard let bodyData = try? JSONEncoder().encode(request),
              let response = await sendPluginRequest(plugin: plugin, path: "stream/end", bodyData: bodyData)
        else {
            return false
        }
        return (200..<300).contains(response.statusCode)
#else
        return false
#endif
    }

#if canImport(FoundationNetworking)
    private func sendPluginRequest(
        plugin: ChannelPluginRecord,
        path: String,
        bodyData: Data
    ) async -> (statusCode: Int, data: Data)? {
        let urlString = plugin.baseUrl.hasSuffix("/")
            ? "\(plugin.baseUrl)\(path)"
            : "\(plugin.baseUrl)/\(path)"

        guard let url = URL(string: urlString) else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        request.timeoutInterval = timeoutInterval

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return nil
            }
            return (http.statusCode, data)
        } catch {
            return nil
        }
    }
#endif
}
