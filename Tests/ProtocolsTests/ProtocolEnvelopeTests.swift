import Foundation
import Testing
@testable import Protocols

@Test
func envelopeRoundTrip() throws {
    let envelope = EventEnvelope(
        messageType: .workerProgress,
        channelId: "general",
        taskId: "task-1",
        workerId: "worker-1",
        payload: .object(["progress": .string("running")])
    )

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(envelope)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(EventEnvelope.self, from: data)

    #expect(decoded.messageType == .workerProgress)
    #expect(decoded.channelId == "general")
    #expect(decoded.taskId == "task-1")
}

@Test
func jsonValueCoderRoundTrip() throws {
    let decision = ChannelRouteDecision(action: .spawnWorker, reason: "test", confidence: 0.9, tokenBudget: 1200)
    let value = try JSONValueCoder.encode(decision)
    let decoded = try JSONValueCoder.decode(ChannelRouteDecision.self, from: value)

    #expect(decoded.action == .spawnWorker)
    #expect(decoded.reason == "test")
}
