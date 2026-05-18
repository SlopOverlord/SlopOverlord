import AnyLanguageModel
import Foundation
import Testing
@testable import PluginSDK
@testable import Protocols
@testable import sloppy

private struct MemoryCheckpointFixedTextModel: LanguageModel {
    typealias UnavailableReason = Never

    func respond<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
        guard type == String.self else {
            fatalError("MemoryCheckpointFixedTextModel only supports String responses")
        }
        let text = "Checkpoint inspected."
        return LanguageModelSession.Response(
            content: text as! Content,
            rawContent: GeneratedContent(text),
            transcriptEntries: []
        )
    }

    func streamResponse<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) -> sending LanguageModelSession.ResponseStream<Content> where Content: Generable {
        let stream = AsyncThrowingStream<LanguageModelSession.ResponseStream<Content>.Snapshot, any Error> { continuation in
            Task {
                guard let response = try? await respond(
                    within: session,
                    to: prompt,
                    generating: type,
                    includeSchemaInPrompt: includeSchemaInPrompt,
                    options: options
                ) else {
                    continuation.finish()
                    return
                }
                continuation.yield(.init(content: response.content.asPartiallyGenerated(), rawContent: response.rawContent))
                continuation.finish()
            }
        }
        return LanguageModelSession.ResponseStream(stream: stream)
    }
}

private actor BlockingMemoryCheckpointModelProvider: ModelProvider {
    nonisolated let id: String = "blocking-memory-checkpoint"
    nonisolated let supportedModels: [String] = ["mock:test-model"]

    private var started = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func createLanguageModel(for modelName: String) async throws -> any LanguageModel {
        started = true
        if !released {
            await withCheckedContinuation { continuation in
                if released {
                    continuation.resume()
                } else {
                    waiters.append(continuation)
                }
            }
        }
        return MemoryCheckpointFixedTextModel()
    }

    func hasStarted() -> Bool {
        started
    }

    func release() {
        released = true
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}

private actor MemoryCheckpointCreationProbe {
    private var finished = false

    func markFinished() {
        finished = true
    }

    func isFinished() -> Bool {
        finished
    }
}

@Test
func createAgentSessionSchedulesNewSessionMemoryCheckpointInBackground() async throws {
    let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
    let provider = BlockingMemoryCheckpointModelProvider()
    await service.overrideModelProviderForTests(provider, defaultModel: "mock:test-model")

    let agentID = "checkpoint-bg-\(UUID().uuidString.lowercased())"
    _ = try await service.createAgent(
        AgentCreateRequest(id: agentID, displayName: "Checkpoint Background", role: "Testing")
    )
    let previous = try await service.createAgentSession(
        agentID: agentID,
        request: AgentSessionCreateRequest(title: "Previous")
    )

    let creationProbe = MemoryCheckpointCreationProbe()
    let creationTask = Task {
        let session = try await service.createAgentSession(
            agentID: agentID,
            request: AgentSessionCreateRequest(
                title: "Next",
                checkpointSessionId: previous.id
            )
        )
        await creationProbe.markFinished()
        return session
    }

    let creationReturnedBeforeCheckpointReleased = await waitForMemoryCheckpointCondition(
        timeoutNanoseconds: 500_000_000
    ) {
        await creationProbe.isFinished()
    }
    #expect(creationReturnedBeforeCheckpointReleased)

    let checkpointStarted = await waitForMemoryCheckpointCondition(timeoutNanoseconds: 2_000_000_000) {
        await provider.hasStarted()
    }
    #expect(checkpointStarted)

    await provider.release()
    let next = try await creationTask.value
    #expect(next.id != previous.id)
}

private func waitForMemoryCheckpointCondition(
    timeoutNanoseconds: UInt64,
    condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await condition()
}
