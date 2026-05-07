import Foundation
import Testing
import SloppyClientCore
@testable import SloppyFeatureChat

@Suite("ChatTranscriptState")
@MainActor
struct ChatTranscriptStateTests {
    @Test("replaceAll exposes the entire loaded session history")
    func replaceAllShowsFullHistory() {
        let transcript = ChatTranscriptState()
        let messages = makeMessages(count: 150)

        transcript.replaceAll(messages)

        #expect(transcript.messages.count == 150)
        #expect(transcript.messages.first?.id == "msg-0")
        #expect(transcript.messages.last?.id == "msg-149")
        #expect(transcript.hasEarlierMessages == false)
        #expect(transcript.hiddenMessageCount == 0)
    }

    @Test("append keeps all messages visible for mouse scrolling")
    func appendKeepsFullHistoryVisible() {
        let transcript = ChatTranscriptState()
        transcript.replaceAll(makeMessages(count: 70))

        transcript.append(message(id: "msg-70", index: 70))

        #expect(transcript.messages.count == 71)
        #expect(transcript.messages.first?.id == "msg-0")
        #expect(transcript.messages.last?.id == "msg-70")
        #expect(transcript.hasEarlierMessages == false)
    }

    @Test("upsert preserves full visible history")
    func upsertPreservesFullVisibleHistory() {
        let transcript = ChatTranscriptState()
        transcript.replaceAll(makeMessages(count: 80))

        transcript.upsert(message(id: "msg-10", index: 10, text: "updated"))
        transcript.upsert(message(id: "msg-80", index: 80))

        #expect(transcript.messages.count == 81)
        #expect(transcript.messages.first?.id == "msg-0")
        #expect(transcript.messages[10].textContent == "updated")
        #expect(transcript.messages.last?.id == "msg-80")
        #expect(transcript.hasEarlierMessages == false)
    }

    private func makeMessages(count: Int) -> [ChatMessage] {
        (0..<count).map { message(id: "msg-\($0)", index: $0) }
    }

    private func message(id: String, index: Int, text: String? = nil) -> ChatMessage {
        ChatMessage(
            id: id,
            role: index.isMultiple(of: 2) ? .user : .assistant,
            segments: [ChatMessageSegment(kind: .text, text: text ?? "message \(index)")],
            createdAt: Date(timeIntervalSince1970: TimeInterval(index))
        )
    }
}
