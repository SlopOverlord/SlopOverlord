import Foundation
import Protocols

public actor EventBus {
    private var subscribers: [UUID: AsyncStream<EventEnvelope>.Continuation] = [:]
    private var bufferedEvents: [EventEnvelope] = []
    private let maxBufferedEvents = 256

    public init() {}

    /// Subscribes caller to a live stream of runtime events.
    public func subscribe() -> AsyncStream<EventEnvelope> {
        let id = UUID()
        return AsyncStream { continuation in
            subscribers[id] = continuation
            if !bufferedEvents.isEmpty {
                for event in bufferedEvents {
                    continuation.yield(event)
                }
                bufferedEvents.removeAll(keepingCapacity: true)
            }
            continuation.onTermination = { [id] _ in
                Task {
                    await self.unsubscribe(id: id)
                }
            }
        }
    }

    /// Broadcasts event to all active subscribers.
    public func publish(_ event: EventEnvelope) {
        if subscribers.isEmpty {
            bufferedEvents.append(event)
            if bufferedEvents.count > maxBufferedEvents {
                bufferedEvents.removeFirst(bufferedEvents.count - maxBufferedEvents)
            }
            return
        }

        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }

    private func unsubscribe(id: UUID) {
        subscribers.removeValue(forKey: id)
    }
}
