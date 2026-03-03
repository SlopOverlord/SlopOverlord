import Foundation
import Testing
@testable import AgentRuntime
@testable import Protocols

/// Regression tests for event payload size limits.
/// These tests ensure runtime events stay within token economy budgets.
///
/// **Why this matters:** Large payloads increase LLM context window costs and
/// can lead to truncated context. This test suite provides early warning when
/// new features inadvertently bloat event sizes.
///
/// **When to update limits:**
/// - If a legitimate new feature requires larger payloads, update `EventPayloadLimits`
///   after review by the team.
/// - Document any limit increases in `docs/specs/runtime-v1.md` with justification.
@Suite("Event Payload Regression Guardrails")
struct EventPayloadRegressionTests {

    // MARK: - Limit Validation

    @Test("Payload size limits are documented and non-zero")
    func payloadLimitsAreConfigured() {
        #expect(EventPayloadLimits.maxBytesPerEventPayload > 0)
        #expect(EventPayloadLimits.warningThresholdBytes > 0)
        #expect(EventPayloadLimits.warningThresholdBytes < EventPayloadLimits.maxBytesPerEventPayload)
    }

    // MARK: - Representative Runtime Scenarios

    @Test("Channel message received event stays within budget")
    func channelMessageReceivedPayloadWithinBudget() async throws {
        let envelope = EventEnvelope(
            messageType: .channelMessageReceived,
            channelId: "ch-test-001",
            payload: .object([
                "userId": .string("user-123"),
                "content": .string("Hello, this is a typical user message"),
                "topicId": .string("topic-456"),
                "timestamp": .string("2026-03-03T14:00:00Z"),
            ])
        )

        try assertPayloadWithinLimit(envelope, scenario: "channel.message.received")
    }

    @Test("Channel route decision event stays within budget")
    func channelRouteDecisionPayloadWithinBudget() async throws {
        let decision = ChannelRouteDecision(
            action: .spawnWorker,
            reason: "User requested task execution",
            confidence: 0.95,
            tokenBudget: 4000
        )

        let envelope = EventEnvelope(
            messageType: .channelRouteDecided,
            channelId: "ch-test-001",
            payload: try encodeToJSONValue(decision)
        )

        try assertPayloadWithinLimit(envelope, scenario: "channel.route.decided")
    }

    @Test("Branch spawned event stays within budget")
    func branchSpawnedPayloadWithinBudget() async throws {
        let envelope = EventEnvelope(
            messageType: .branchSpawned,
            channelId: "ch-test-001",
            branchId: "branch-789",
            payload: .object([
                "prompt": .string("Research the best approach for implementation"),
                "contextSnapshotId": .string("snap-abc-123"),
                "estimatedComplexity": .string("medium"),
            ])
        )

        try assertPayloadWithinLimit(envelope, scenario: "branch.spawned")
    }

    @Test("Branch conclusion event stays within budget")
    func branchConclusionPayloadWithinBudget() async throws {
        let conclusion = BranchConclusion(
            summary: "Implementation approach selected based on performance benchmarks.",
            artifactRefs: [
                ArtifactRef(id: "art-001", kind: "benchmark", preview: "Results show 20% improvement"),
                ArtifactRef(id: "art-002", kind: "design", preview: "Architecture diagram"),
            ],
            memoryRefs: [
                MemoryRef(id: "mem-001", score: 0.95),
                MemoryRef(id: "mem-002", score: 0.87),
            ],
            tokenUsage: TokenUsage(prompt: 1500, completion: 800)
        )

        let envelope = EventEnvelope(
            messageType: .branchConclusion,
            channelId: "ch-test-001",
            branchId: "branch-789",
            payload: try encodeToJSONValue(conclusion)
        )

        try assertPayloadWithinLimit(envelope, scenario: "branch.conclusion")
    }

    @Test("Worker spawned event stays within budget")
    func workerSpawnedPayloadWithinBudget() async throws {
        let spec = WorkerTaskSpec(
            taskId: "task-001",
            channelId: "ch-test-001",
            title: "Implement feature X",
            objective: "Create a module that handles user authentication with proper validation",
            tools: ["shell", "file_read", "file_write"],
            mode: .interactive
        )

        let envelope = EventEnvelope(
            messageType: .workerSpawned,
            channelId: "ch-test-001",
            workerId: "worker-001",
            payload: try encodeToJSONValue(spec)
        )

        try assertPayloadWithinLimit(envelope, scenario: "worker.spawned")
    }

    @Test("Worker progress event stays within budget")
    func workerProgressPayloadWithinBudget() async throws {
        let envelope = EventEnvelope(
            messageType: .workerProgress,
            channelId: "ch-test-001",
            workerId: "worker-001",
            payload: .object([
                "step": .number(3),
                "totalSteps": .number(5),
                "status": .string("in_progress"),
                "currentAction": .string("Validating user input schema"),
                "completionPercentage": .number(0.6),
            ])
        )

        try assertPayloadWithinLimit(envelope, scenario: "worker.progress")
    }

    @Test("Worker completed event stays within budget")
    func workerCompletedPayloadWithinBudget() async throws {
        let envelope = EventEnvelope(
            messageType: .workerCompleted,
            channelId: "ch-test-001",
            workerId: "worker-001",
            payload: .object([
                "result": .string("Successfully implemented authentication module"),
                "artifactIds": .array([.string("art-auth-001"), .string("art-auth-002")]),
                "tokenUsage": .object([
                    "prompt": .number(2500),
                    "completion": .number(1200),
                ]),
                "durationSeconds": .number(45.5),
            ])
        )

        try assertPayloadWithinLimit(envelope, scenario: "worker.completed")
    }

    @Test("Worker failed event stays within budget")
    func workerFailedPayloadWithinBudget() async throws {
        let envelope = EventEnvelope(
            messageType: .workerFailed,
            channelId: "ch-test-001",
            workerId: "worker-001",
            payload: .object([
                "error": .string("Tool execution timeout after 30 seconds"),
                "errorCode": .string("TOOL_TIMEOUT"),
                "retryable": .bool(true),
                "failedStep": .number(2),
            ])
        )

        try assertPayloadWithinLimit(envelope, scenario: "worker.failed")
    }

    @Test("Compactor threshold hit event stays within budget")
    func compactorThresholdHitPayloadWithinBudget() async throws {
        let job = CompactionJob(
            channelId: "ch-test-001",
            level: .aggressive,
            threshold: 0.87
        )

        let envelope = EventEnvelope(
            messageType: .compactorThresholdHit,
            channelId: "ch-test-001",
            payload: try encodeToJSONValue(job)
        )

        try assertPayloadWithinLimit(envelope, scenario: "compactor.threshold.hit")
    }

    @Test("Compactor summary applied event stays within budget")
    func compactorSummaryAppliedPayloadWithinBudget() async throws {
        let envelope = EventEnvelope(
            messageType: .compactorSummaryApplied,
            channelId: "ch-test-001",
            payload: .object([
                "summaryId": .string("sum-001"),
                "compactionLevel": .string("aggressive"),
                "eventsCompacted": .number(150),
                "contextReductionBytes": .number(8192),
                "newContextWindow": .string("25%"),
            ])
        )

        try assertPayloadWithinLimit(envelope, scenario: "compactor.summary.applied")
    }

    @Test("Visor bulletin generated event stays within budget")
    func visorBulletinGeneratedPayloadWithinBudget() async throws {
        let bulletin = MemoryBulletin(
            headline: "Channel Activity Summary",
            digest: "2 workers completed, 1 branch concluded, 3 new artifacts created",
            items: [
                "Worker worker-001 completed task-001",
                "Branch branch-789 concluded with 2 artifacts",
                "New artifacts: art-001, art-002, art-003",
            ]
        )

        let envelope = EventEnvelope(
            messageType: .visorBulletinGenerated,
            channelId: "ch-test-001",
            payload: try encodeToJSONValue(bulletin)
        )

        try assertPayloadWithinLimit(envelope, scenario: "visor.bulletin.generated")
    }

    // MARK: - Stress Tests

    @Test("Large payload with many artifact refs stays within budget")
    func largeArtifactRefsListWithinBudget() async throws {
        // Generate many artifact refs to test edge case
        var artifactRefs: [ArtifactRef] = []
        for i in 0..<20 {
            artifactRefs.append(ArtifactRef(
                id: "art-\(i)",
                kind: "file",
                preview: "Preview content for artifact \(i) with some descriptive text"
            ))
        }

        let conclusion = BranchConclusion(
            summary: "Complex analysis completed with multiple outputs.",
            artifactRefs: artifactRefs,
            memoryRefs: [],
            tokenUsage: TokenUsage(prompt: 5000, completion: 3000)
        )

        let envelope = EventEnvelope(
            messageType: .branchConclusion,
            channelId: "ch-test-001",
            branchId: "branch-999",
            payload: try encodeToJSONValue(conclusion)
        )

        try assertPayloadWithinLimit(envelope, scenario: "branch.conclusion with 20 artifacts")
    }

    @Test("Payload with large extensions stays within budget")
    func payloadWithExtensionsWithinBudget() async throws {
        let envelope = EventEnvelope(
            messageType: .workerCompleted,
            channelId: "ch-test-001",
            workerId: "worker-001",
            payload: .object([
                "result": .string("Success"),
            ]),
            extensions: [
                "debug_info": .object([
                    "execution_trace": .array((0..<10).map { .string("Step \($0) completed") }),
                    "memory_snapshots": .array([.string("snap-1"), .string("snap-2")]),
                ]),
                "metrics": .object([
                    "cpu_percent": .number(45.5),
                    "memory_mb": .number(128.0),
                    "io_operations": .number(42),
                ]),
            ]
        )

        try assertPayloadWithinLimit(envelope, scenario: "worker.completed with extensions")
    }

    // MARK: - Limit Enforcement Tests

    @Test("isPayloadOversized returns true when limit exceeded")
    func payloadOversizedDetection() async {
        let largeContent = String(repeating: "x", count: 20_000)
        let envelope = EventEnvelope(
            messageType: .channelMessageReceived,
            channelId: "ch-test-001",
            payload: .object([
                "content": .string(largeContent),
            ])
        )

        #expect(envelope.isPayloadOversized() == true)
        #expect(envelope.isPayloadNearLimit() == true)
    }

    @Test("isPayloadNearLimit returns true at 80% threshold")
    func payloadNearLimitDetection() async throws {
        // Create a payload that is ~85% of the limit
        let targetSize = Int(Double(EventPayloadLimits.maxBytesPerEventPayload) * 0.85)
        let paddingSize = targetSize - 100  // Account for JSON overhead
        let content = String(repeating: "a", count: max(0, paddingSize))

        let envelope = EventEnvelope(
            messageType: .workerProgress,
            channelId: "ch-test-001",
            workerId: "worker-001",
            payload: .object([
                "status": .string("in_progress"),
                "content": .string(content),
            ])
        )

        #expect(envelope.isPayloadNearLimit() == true)
        #expect(envelope.isPayloadOversized() == false)
    }

    // MARK: - Size Reporting

    @Test("Payload size measurement is accurate")
    func payloadSizeMeasurementAccuracy() async throws {
        let envelope = EventEnvelope(
            messageType: .channelMessageReceived,
            channelId: "ch-test-001",
            payload: .string("test content")
        )

        let size = envelope.payloadSizeInBytes()
        #expect(size > 0)

        // Verify by manual encoding
        let encoder = JSONEncoder()
        let data = try encoder.encode(JSONValue.string("test content"))
        #expect(size == data.count)
    }

    // MARK: - Helpers

    /// Asserts that an envelope's payload is within the configured limit.
    /// Fails fast with a clear report showing the limit, actual size, and overshoot.
    private func assertPayloadWithinLimit(
        _ envelope: EventEnvelope,
        scenario: String
    ) throws {
        let payloadSize = envelope.payloadSizeInBytes()
        let limit = EventPayloadLimits.maxBytesPerEventPayload
        let extensionsSize = envelope.extensionsSizeInBytes()
        let totalSize = envelope.totalContentSizeInBytes()

        // Build diagnostic report
        var report = ""
        report += "========================================\n"
        report += "PAYLOAD SIZE REGRESSION DETECTED\n"
        report += "========================================\n"
        report += "Scenario: \(scenario)\n"
        report += "Message Type: \(envelope.messageType)\n"
        report += "Channel: \(envelope.channelId)\n"
        report += "----------------------------------------\n"
        report += "Payload Size:      \(formatBytes(payloadSize))\n"
        report += "Extensions Size:   \(formatBytes(extensionsSize))\n"
        report += "Total Content:     \(formatBytes(totalSize))\n"
        report += "----------------------------------------\n"
        report += "Limit:             \(formatBytes(limit))\n"
        if payloadSize > limit {
            let overshoot = payloadSize - limit
            let percentage = (Double(overshoot) / Double(limit)) * 100
            report += "OVERSHOOT:         +\(formatBytes(overshoot)) (\(String(format: "%.1f", percentage))%)\n"
        }
        report += "========================================\n"

        // Fail-fast with clear diff
        if payloadSize > limit {
            throw PayloadLimitExceededError(
                message: report,
                scenario: scenario,
                payloadSize: payloadSize,
                limit: limit
            )
        }

        // Also assert via #expect for test reporting
        #expect(payloadSize <= limit, "Payload exceeds limit for \(scenario). \(report)")

        // Warn if near limit
        if envelope.isPayloadNearLimit() {
            let usagePercent = (Double(payloadSize) / Double(limit)) * 100
            print("⚠️  Warning: \(scenario) payload at \(String(format: "%.1f", usagePercent))% of limit")
        }
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.2f KB", Double(bytes) / 1024.0)
        } else {
            return String(format: "%.2f MB", Double(bytes) / (1024.0 * 1024.0))
        }
    }

    private func encodeToJSONValue<T: Encodable>(_ value: T) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(JSONValue.self, from: data)
    }
}

/// Error thrown when a payload exceeds the configured limit.
struct PayloadLimitExceededError: Error, CustomStringConvertible {
    let message: String
    let scenario: String
    let payloadSize: Int
    let limit: Int

    var description: String { message }
}
