import Foundation
import Logging
import Protocols

/// Configuration for periodic visor bulletin generation.
public struct VisorSchedulerConfig: Sendable {
    /// Base interval between bulletins.
    public var interval: Duration
    /// Random jitter to add to each interval (0..<jitter).
    public var jitter: Duration

    public init(
        interval: Duration = .seconds(300),
        jitter: Duration = .seconds(60)
    ) {
        self.interval = interval
        self.jitter = jitter
    }

    /// Default configuration: 5 minute interval with 1 minute jitter.
    public static let `default` = VisorSchedulerConfig()
}

/// Actor that schedules periodic visor bulletin generation.
/// - Ensures cancel-safe operation
/// - Protects against overlapping runs
/// - Adds configurable jitter to prevent thundering herd
public actor VisorScheduler {
    private let config: VisorSchedulerConfig
    private let logger: Logger
    private var task: Task<Void, Never>?
    private var isRunning = false
    private var isBulletinGenerationInProgress = false
    private let bulletinGenerator: @Sendable () async -> Void

    /// Creates a new scheduler instance.
    /// - Parameters:
    ///   - config: Scheduler configuration
    ///   - logger: Logger instance
    ///   - bulletinGenerator: Closure that generates the bulletin
    public init(
        config: VisorSchedulerConfig = .default,
        logger: Logger,
        bulletinGenerator: @escaping @Sendable () async -> Void
    ) {
        self.config = config
        self.logger = logger
        self.bulletinGenerator = bulletinGenerator
    }

    deinit {
        task?.cancel()
    }

    /// Starts the periodic scheduler loop.
    /// Has no effect if already running.
    public func start() {
        guard task == nil else {
            logger.warning("VisorScheduler.start() called but already running")
            return
        }

        logger.info("Starting VisorScheduler with interval \(config.interval) and jitter \(config.jitter)")
        isRunning = true

        task = Task { [weak self] in
            while let self = self, !Task.isCancelled {
                // Sleep with jitter before first run to avoid immediate execution
                let jitter = await self.calculateJitter()
                let sleepDuration = self.config.interval + jitter

                logger.debug("VisorScheduler sleeping for \(sleepDuration)")

                do {
                    try await Task.sleep(for: sleepDuration)
                } catch {
                    logger.debug("VisorScheduler sleep interrupted: \(error)")
                    break
                }

                guard !Task.isCancelled else { break }

                await self.generateBulletinIfNotOverlapping()
            }
            await self?.markStopped()
        }
    }

    /// Stops the scheduler and cancels any pending operation.
    public func stop() {
        logger.info("Stopping VisorScheduler")
        task?.cancel()
        task = nil
        isRunning = false
    }

    /// Returns true if the scheduler is currently running.
    public func running() -> Bool {
        isRunning
    }

    /// Triggers immediate bulletin generation if not already running.
    /// Returns true if generation was started, false if skipped due to overlap.
    @discardableResult
    public func triggerImmediately() async -> Bool {
        await generateBulletinIfNotOverlapping()
    }

    // MARK: - Private

    private func calculateJitter() -> Duration {
        let jitterSeconds = Double(config.jitter.components.seconds)
        guard jitterSeconds > 0 else { return .seconds(0) }
        let randomJitter = Double.random(in: 0..<jitterSeconds)
        return .seconds(randomJitter)
    }

    @discardableResult
    private func generateBulletinIfNotOverlapping() async -> Bool {
        guard !isBulletinGenerationInProgress else {
            logger.warning("Skipping bulletin generation: previous run still in progress")
            return false
        }

        isBulletinGenerationInProgress = true
        defer { isBulletinGenerationInProgress = false }

        logger.info("Generating periodic visor bulletin")
        await bulletinGenerator()
        logger.info("Periodic visor bulletin generated successfully")
        return true
    }

    private func markStopped() {
        isRunning = false
    }
}
