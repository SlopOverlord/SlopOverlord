import Foundation
import Protocols

struct SloppyTUIQueuedMessage: Identifiable {
    var id: Int
    var text: String
    var context: String?
    var uploads: [AgentAttachmentUpload]
    var spawnSubSession: Bool

    var displayText: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        if !uploads.isEmpty {
            return "(attachments only)"
        }
        if context?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return "(context only)"
        }
        return "(empty message)"
    }
}

struct SloppyTUIMessageQueue {
    private(set) var messages: [SloppyTUIQueuedMessage] = []
    private var nextID = 1

    var isEmpty: Bool { messages.isEmpty }
    var count: Int { messages.count }

    mutating func enqueue(
        text: String,
        context: String? = nil,
        uploads: [AgentAttachmentUpload] = [],
        spawnSubSession: Bool = false
    ) -> SloppyTUIQueuedMessage {
        let message = SloppyTUIQueuedMessage(
            id: nextID,
            text: text,
            context: context,
            uploads: uploads,
            spawnSubSession: spawnSubSession
        )
        nextID += 1
        messages.append(message)
        return message
    }

    mutating func dequeue() -> SloppyTUIQueuedMessage? {
        guard !messages.isEmpty else { return nil }
        return messages.removeFirst()
    }

    mutating func cancelNext() -> SloppyTUIQueuedMessage? {
        dequeue()
    }

    mutating func cancel(id: Int) -> SloppyTUIQueuedMessage? {
        guard let index = messages.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        return messages.remove(at: index)
    }
}
