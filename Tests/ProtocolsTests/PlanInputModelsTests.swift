import Foundation
import Protocols
import Testing

@Suite("Plan input protocol models")
struct PlanInputModelsTests {
    @Test("plan input request and response round-trip through session event")
    func planInputRoundTrip() throws {
        let request = PlanInputRequest(
            id: "req-1",
            title: "Choose direction",
            questions: [
                PlanInputQuestion(
                    id: "direction",
                    header: "Scope",
                    question: "What should we do?",
                    options: [
                        PlanInputOption(id: "small", label: "Small"),
                        PlanInputOption(id: "large", label: "Large", description: "Broader work")
                    ]
                )
            ],
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let response = PlanInputResponse(
            requestId: "req-1",
            status: .answered,
            answers: [PlanInputAnswer(questionId: "direction", selectedOptionId: "small")],
            userId: "tester",
            createdAt: Date(timeIntervalSince1970: 20)
        )
        let event = AgentSessionEvent(
            id: "event-1",
            agentId: "assistant",
            sessionId: "session-1",
            type: .inputRequest,
            inputRequest: request,
            inputResponse: response
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(event)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AgentSessionEvent.self, from: data)

        #expect(decoded.type == .inputRequest)
        #expect(decoded.inputRequest?.questions.first?.allowCustomAnswer == true)
        #expect(decoded.inputRequest?.questions.first?.options.last?.description == "Broader work")
        #expect(decoded.inputResponse?.answers.first?.selectedOptionId == "small")
    }
}
