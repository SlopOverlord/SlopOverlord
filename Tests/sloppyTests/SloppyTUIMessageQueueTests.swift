import Protocols
import Testing

@testable import sloppy

@Test func queuedMessagesDequeueInSubmissionOrder() {
    var queue = SloppyTUIMessageQueue()

    let first = queue.enqueue(text: "first")
    let second = queue.enqueue(text: "second", spawnSubSession: true)

    #expect(queue.count == 2)
    #expect(first.id != second.id)
    #expect(queue.dequeue()?.text == "first")
    #expect(queue.dequeue()?.text == "second")
    #expect(queue.dequeue() == nil)
    #expect(queue.isEmpty)
}

@Test func queuedMessagesCanCancelNextMessage() {
    var queue = SloppyTUIMessageQueue()
    _ = queue.enqueue(text: "cancel me")
    _ = queue.enqueue(text: "keep me")

    let canceled = queue.cancelNext()

    #expect(canceled?.text == "cancel me")
    #expect(queue.count == 1)
    #expect(queue.dequeue()?.text == "keep me")
}

@Test func queuedMessageDisplayTextDescribesAttachmentsOnlyMessage() {
    let message = SloppyTUIQueuedMessage(
        id: 1,
        text: "   ",
        context: nil,
        uploads: [AgentAttachmentUpload(name: "image.png", mimeType: "image/png", sizeBytes: 10)],
        spawnSubSession: false
    )

    #expect(message.displayText == "(attachments only)")
}

@Test func queuedMessageThemeRendersStickyCancelHint() {
    let message = SloppyTUIQueuedMessage(
        id: 1,
        text: "queued body",
        context: "extra context",
        uploads: [],
        spawnSubSession: false
    )

    let rendered = SloppyTUITheme.queuedMessageLines(message, width: 80).joined(separator: "\n")

    #expect(rendered.contains("queued"))
    #expect(rendered.contains("ctrl+b cancels"))
    #expect(rendered.contains("queued body"))
    #expect(rendered.contains("context"))
}
