import XCTest
@testable import Protocols

final class ProtocolEnvelopeTests: XCTestCase {
    func testEnvelopeRoundTrip() throws {
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

        XCTAssertEqual(decoded.messageType, .workerProgress)
        XCTAssertEqual(decoded.channelId, "general")
        XCTAssertEqual(decoded.taskId, "task-1")
    }

    func testJSONValueCoderRoundTrip() throws {
        let decision = ChannelRouteDecision(action: .spawnWorker, reason: "test", confidence: 0.9, tokenBudget: 1200)
        let value = try JSONValueCoder.encode(decision)
        let decoded = try JSONValueCoder.decode(ChannelRouteDecision.self, from: value)

        XCTAssertEqual(decoded.action, .spawnWorker)
        XCTAssertEqual(decoded.reason, "test")
    }
}
