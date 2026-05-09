import Foundation
import AgentRuntime
import Protocols
import Logging

public actor CronRunner {
    private let store: any PersistenceStore
    private let runtime: RuntimeSystem
    private let notificationService: NotificationService?
    private let logger: Logger
    private var task: Task<Void, Never>?
    private var isRunning = false
    
    private var lastRunMinuteStr: String?

    public init(
        store: any PersistenceStore,
        runtime: RuntimeSystem,
        notificationService: NotificationService? = nil,
        logger: Logger = Logger(label: "sloppy.core.cron")
    ) {
        self.store = store
        self.runtime = runtime
        self.notificationService = notificationService
        self.logger = logger
    }
    
    deinit {
        task?.cancel()
    }

    public func start() {
        guard task == nil else {
            logger.warning("CronRunner start() called but already running")
            return
        }
        
        logger.info("Starting CronRunner")
        isRunning = true
        task = Task { [weak self] in
            while let self = self, !Task.isCancelled {
                let now = Date()
                let calendar = Calendar.current
                let currentSecond = calendar.component(.second, from: now)
                
                let sleepDuration = 60 - currentSecond + 1
                
                try? await Task.sleep(nanoseconds: UInt64(sleepDuration) * 1_000_000_000)
                guard !Task.isCancelled else { break }
                
                await self.tick(date: Date())
            }
        }
    }
    
    public func stop() {
        logger.info("Stopping CronRunner")
        task?.cancel()
        task = nil
        isRunning = false
    }
    
    private func tick(date: Date) async {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let currentMinuteStr = formatter.string(from: date)
        
        guard currentMinuteStr != lastRunMinuteStr else {
            return
        }
        lastRunMinuteStr = currentMinuteStr
        
        logger.debug("CronRunner tick at \(currentMinuteStr)")
        
        let allTasks = await store.listAllCronTasks()
        let activeTasks = allTasks.filter { $0.enabled }
        
        for cronTask in activeTasks {
            if CronEvaluator.isDue(cronExpression: cronTask.schedule, date: date) {
                logger.info("Firing cron task \(cronTask.id) for agent \(cronTask.agentId)")
                await executeTask(cronTask)
            }
        }
    }
    
    private func executeTask(_ cronTask: AgentCronTask) async {
        let request = ChannelMessageRequest(
            userId: "system_cron",
            content: """
            CRON TRIGGER: \(cronTask.command)

            Cron metadata:
            - source: cron
            - cronTaskId: \(cronTask.id)
            """,
            topicId: nil
        )
        
        _ = await runtime.postMessage(channelId: cronTask.channelId, request: request)
    }
}
