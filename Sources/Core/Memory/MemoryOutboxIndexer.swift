import Foundation
import Logging

actor MemoryOutboxIndexer {
    private let store: HybridMemoryStore
    private let logger: Logger
    private let intervalNanoseconds: UInt64
    private var task: Task<Void, Never>?

    init(
        store: HybridMemoryStore,
        logger: Logger = Logger(label: "sloppy.memory.outbox"),
        intervalNanoseconds: UInt64 = 2_000_000_000
    ) {
        self.store = store
        self.logger = logger
        self.intervalNanoseconds = intervalNanoseconds
    }

    func start() {
        guard task == nil else {
            return
        }

        task = Task { [weak self] in
            guard let self else {
                return
            }
            while !Task.isCancelled {
                let processed = await self.store.flushOutbox(limit: 50)
                if processed > 0 {
                    self.logger.debug("memory.outbox.flush processed \(processed) row(s)")
                }
                try? await Task.sleep(nanoseconds: self.intervalNanoseconds)
            }
        }
    }

    func stop() async {
        task?.cancel()
        task = nil
    }
}
