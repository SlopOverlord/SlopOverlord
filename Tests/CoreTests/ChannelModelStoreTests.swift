import Foundation
import Protocols
import Testing
@testable import Core

@Test
func channelModelStoreGetSetAndPersist() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("channel-model-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = ChannelModelStore(workspaceRootURL: dir)

    #expect(await store.get(channelId: "general") == nil)

    await store.set(channelId: "general", model: "openai:gpt-4.1-mini")
    #expect(await store.get(channelId: "general") == "openai:gpt-4.1-mini")

    // Reload from disk
    let reloaded = ChannelModelStore(workspaceRootURL: dir)
    #expect(await reloaded.get(channelId: "general") == "openai:gpt-4.1-mini")
}

@Test
func channelModelStoreRemove() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("channel-model-store-remove-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = ChannelModelStore(workspaceRootURL: dir)
    await store.set(channelId: "support", model: "openai:gpt-4.1-mini")
    #expect(await store.get(channelId: "support") != nil)

    await store.remove(channelId: "support")
    #expect(await store.get(channelId: "support") == nil)

    // Persisted as removed
    let reloaded = ChannelModelStore(workspaceRootURL: dir)
    #expect(await reloaded.get(channelId: "support") == nil)
}

@Test
func channelModelEndpointGetReturnsAvailableModels() async throws {
    let service = CoreService(config: .default)
    let router = CoreRouter(service: service)

    let response = await router.handle(method: "GET", path: "/v1/channels/general/model", body: nil)
    #expect(response.status == 200)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let body = try decoder.decode(ChannelModelResponse.self, from: response.body)
    #expect(body.channelId == "general")
    #expect(body.selectedModel == nil)
    #expect(!body.availableModels.isEmpty)
}

@Test
func channelModelEndpointSetAndGet() async throws {
    let service = CoreService(config: .default)
    let router = CoreRouter(service: service)
    let channelId = "model-test-\(UUID().uuidString)"

    let available = await service.getChannelModel(channelId: channelId).availableModels
    guard let firstModel = available.first else { return }

    let putBody = try JSONEncoder().encode(ChannelModelUpdateRequest(model: firstModel.id))
    let putResponse = await router.handle(
        method: "PUT",
        path: "/v1/channels/\(channelId)/model",
        body: putBody
    )
    #expect(putResponse.status == 200)

    let getResponse = await router.handle(method: "GET", path: "/v1/channels/\(channelId)/model", body: nil)
    #expect(getResponse.status == 200)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let body = try decoder.decode(ChannelModelResponse.self, from: getResponse.body)
    #expect(body.selectedModel == firstModel.id)
}

@Test
func channelModelEndpointRejectsInvalidModel() async throws {
    let service = CoreService(config: .default)
    let router = CoreRouter(service: service)

    let putBody = try JSONEncoder().encode(ChannelModelUpdateRequest(model: "not-a-real-model"))
    let response = await router.handle(
        method: "PUT",
        path: "/v1/channels/general/model",
        body: putBody
    )
    #expect(response.status == 400)
}

@Test
func channelModelEndpointDelete() async throws {
    let service = CoreService(config: .default)
    let router = CoreRouter(service: service)
    let channelId = "model-delete-\(UUID().uuidString)"

    let available = await service.getChannelModel(channelId: channelId).availableModels
    guard let firstModel = available.first else { return }

    let putBody = try JSONEncoder().encode(ChannelModelUpdateRequest(model: firstModel.id))
    _ = await router.handle(method: "PUT", path: "/v1/channels/\(channelId)/model", body: putBody)

    let deleteResponse = await router.handle(
        method: "DELETE",
        path: "/v1/channels/\(channelId)/model",
        body: nil
    )
    #expect(deleteResponse.status == 200)

    let getResponse = await router.handle(method: "GET", path: "/v1/channels/\(channelId)/model", body: nil)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let body = try decoder.decode(ChannelModelResponse.self, from: getResponse.body)
    #expect(body.selectedModel == nil)
}

@Test
func modelCommandListReturnsAvailableModels() async throws {
    let service = CoreService(config: .default)
    let channelId = "model-cmd-\(UUID().uuidString)"

    let ok = await service.postMessage(channelId: channelId, userId: "tg:1", content: "/model")
    #expect(ok)
}

@Test
func modelCommandSetStoresOverride() async throws {
    let service = CoreService(config: .default)
    let channelId = "model-set-\(UUID().uuidString)"

    let channelModelResponse = await service.getChannelModel(channelId: channelId)
    guard let firstModel = channelModelResponse.availableModels.first else { return }

    let ok = await service.postMessage(channelId: channelId, userId: "tg:1", content: "/model \(firstModel.id)")
    #expect(ok)

    let stored = await service.getChannelModel(channelId: channelId)
    #expect(stored.selectedModel == firstModel.id)
}

@Test
func modelCommandRejectsUnknownModel() async throws {
    let service = CoreService(config: .default)
    let channelId = "model-reject-\(UUID().uuidString)"

    let ok = await service.postMessage(channelId: channelId, userId: "tg:1", content: "/model unknown-model-xyz")
    #expect(ok)

    let stored = await service.getChannelModel(channelId: channelId)
    #expect(stored.selectedModel == nil)
}
