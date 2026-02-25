import Foundation
import Protocols

public actor EventBus {
    private var subscribers: [UUID: AsyncStream<EventEnvelope>.Continuation] = [:]

    public init() {}

    /// Subscribes caller to a live stream of runtime events.
    public func subscribe() -> AsyncStream<EventEnvelope> {
        let id = UUID()
        return AsyncStream { continuation in
            subscribers[id] = continuation
            continuation.onTermination = { [id] _ in
                Task {
                    await self.unsubscribe(id: id)
                }
            }
        }
    }

    /// Broadcasts event to all active subscribers.
    public func publish(_ event: EventEnvelope) {
        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }

    private func unsubscribe(id: UUID) {
        subscribers.removeValue(forKey: id)
    }
}
