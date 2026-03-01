import Foundation
import Testing
@testable import AgentRuntime
@testable import Protocols

@Test
func todoExtractorParsesChecklistTodoAndImperativeLines() {
    let prompt = """
    - [ ] Подготовить API контракт
    TODO: Подготовить API контракт
    todo починить flaky тест
    нужно проверить релизный сценарий
    надо
    """

    let todos = TodoExtractor.extractCandidates(from: prompt)

    #expect(todos.count == 3)
    #expect(todos.contains("Подготовить API контракт"))
    #expect(todos.contains("починить flaky тест"))
    #expect(todos.contains("нужно проверить релизный сценарий"))
}

@Test
func branchSpawnStoresTodosAndPublishesExtensions() async throws {
    let bus = EventBus()
    let memory = InMemoryMemoryStore()
    let branchRuntime = BranchRuntime(eventBus: bus, memoryStore: memory)
    let stream = await bus.subscribe()

    let eventTask = Task {
        await firstEvent(matching: .branchSpawned, in: stream)
    }

    _ = await branchRuntime.spawn(
        channelId: "general",
        prompt: """
        research and extract tasks
        - [ ] Ship dashboard cards
        TODO: Ship dashboard cards
        сделай прогон smoke тестов
        """
    )

    let event = await eventTask.value
    let todos = event?.extensions["todos"]?.stringArrayValue ?? []
    #expect(todos.count == 2)
    #expect(todos.contains("Ship dashboard cards"))
    #expect(todos.contains("сделай прогон smoke тестов"))

    let notes = await memory.entries().map(\.note)
    #expect(notes.contains("[todo] Ship dashboard cards"))
    #expect(notes.contains("[todo] сделай прогон smoke тестов"))
}

private func firstEvent(
    matching type: MessageType,
    in stream: AsyncStream<EventEnvelope>,
    timeoutNanoseconds: UInt64 = 1_000_000_000
) async -> EventEnvelope? {
    await withTaskGroup(of: EventEnvelope?.self) { group in
        group.addTask {
            for await event in stream {
                if event.messageType == type {
                    return event
                }
            }
            return nil
        }

        group.addTask {
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            return nil
        }

        let event = await group.next() ?? nil
        group.cancelAll()
        return event
    }
}

private extension JSONValue {
    var stringArrayValue: [String]? {
        guard case .array(let array) = self else {
            return nil
        }
        return array.compactMap { value in
            if case .string(let text) = value {
                return text
            }
            return nil
        }
    }
}
