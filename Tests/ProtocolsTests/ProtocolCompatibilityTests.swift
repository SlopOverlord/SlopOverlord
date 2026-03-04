import Foundation
import Testing
@testable import Protocols

// MARK: - Schema Evolution Compatibility Tests
//
// This test suite verifies backward and forward compatibility of protocol models.
// Key principles:
// - Unknown fields must not break deserialization (forward compatibility)
// - Additive fields (new optional fields) must work seamlessly
// - Removing fields is a breaking change and requires major version bump
// - Changing field types is a breaking change
//
// Expected behavior for forward compatibility:
// - Swift's synthesized Codable ignores unknown keys by default
// - This is the desired behavior for schema evolution

// MARK: - EventEnvelope Compatibility

@Test
func envelopeDecodesWithUnknownFields() throws {
    // Given: JSON with extra fields not defined in EventEnvelope
    let jsonWithUnknownFields = """
    {
        "protocolVersion": "1.0",
        "messageId": "msg-123",
        "messageType": "worker.progress",
        "ts": "2026-03-04T07:00:00Z",
        "traceId": "trace-456",
        "channelId": "general",
        "taskId": "task-789",
        "workerId": "worker-abc",
        "payload": {"progress": "running"},
        "extensions": {},
        "unknownField1": "should be ignored",
        "unknownField2": 42,
        "unknownNested": {"key": "value"}
    }
    """.data(using: .utf8)!

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    // When: Decoding JSON with unknown fields
    let envelope = try decoder.decode(EventEnvelope.self, from: jsonWithUnknownFields)

    // Then: Known fields are decoded correctly, unknown fields are ignored
    #expect(envelope.protocolVersion == "1.0")
    #expect(envelope.messageId == "msg-123")
    #expect(envelope.messageType == .workerProgress)
    #expect(envelope.channelId == "general")
    #expect(envelope.taskId == "task-789")
    #expect(envelope.workerId == "worker-abc")
    #expect(envelope.extensions.isEmpty)
}

@Test
func envelopeDecodesWithoutOptionalFields() throws {
    // Given: JSON without optional fields (taskId, branchId, workerId)
    // Note: extensions is required by synthesized Codable (has no default in struct definition)
    let jsonWithMinimalFields = """
    {
        "protocolVersion": "1.0",
        "messageId": "msg-123",
        "messageType": "channel.message.received",
        "ts": "2026-03-04T07:00:00Z",
        "traceId": "trace-456",
        "channelId": "general",
        "payload": {"content": "hello"},
        "extensions": {}
    }
    """.data(using: .utf8)!

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    // When: Decoding minimal JSON
    let envelope = try decoder.decode(EventEnvelope.self, from: jsonWithMinimalFields)

    // Then: Optional fields are nil/empty, required fields are set
    #expect(envelope.channelId == "general")
    #expect(envelope.taskId == nil)
    #expect(envelope.branchId == nil)
    #expect(envelope.workerId == nil)
    #expect(envelope.extensions.isEmpty)
}

@Test
func envelopeRoundTripPreservesData() throws {
    // Given: A complete envelope with all fields
    let original = EventEnvelope(
        protocolVersion: "1.0",
        messageId: "test-msg",
        messageType: .workerCompleted,
        ts: Date(timeIntervalSince1970: 1700000000),
        traceId: "test-trace",
        channelId: "test-channel",
        taskId: "test-task",
        branchId: "test-branch",
        workerId: "test-worker",
        payload: .object(["result": .string("success")]),
        extensions: ["key": .string("value")]
    )

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    // When: Encoding and decoding
    let data = try encoder.encode(original)
    let decoded = try decoder.decode(EventEnvelope.self, from: data)

    // Then: All fields are preserved
    #expect(decoded.protocolVersion == original.protocolVersion)
    #expect(decoded.messageId == original.messageId)
    #expect(decoded.messageType == original.messageType)
    #expect(decoded.traceId == original.traceId)
    #expect(decoded.channelId == original.channelId)
    #expect(decoded.taskId == original.taskId)
    #expect(decoded.branchId == original.branchId)
    #expect(decoded.workerId == original.workerId)
    #expect(decoded.extensions["key"]?.asString == "value")
}

// MARK: - RuntimeModels Compatibility

@Test
func channelRouteDecisionDecodesWithUnknownFields() throws {
    // Given: JSON with extra fields
    let json = """
    {
        "action": "spawn_worker",
        "reason": "test reason",
        "confidence": 0.95,
        "tokenBudget": 2000,
        "unknownField": "ignored",
        "extraData": {"nested": true}
    }
    """.data(using: .utf8)!

    // When: Decoding
    let decision = try JSONDecoder().decode(ChannelRouteDecision.self, from: json)

    // Then: Known fields decoded, unknown ignored
    #expect(decision.action == .spawnWorker)
    #expect(decision.reason == "test reason")
    #expect(decision.confidence == 0.95)
    #expect(decision.tokenBudget == 2000)
}

@Test
func workerTaskSpecDecodesWithUnknownFields() throws {
    // Given: JSON with extra fields
    let json = """
    {
        "taskId": "task-123",
        "channelId": "channel-456",
        "title": "Test Task",
        "objective": "Test objective",
        "tools": ["tool1", "tool2"],
        "mode": "interactive",
        "priority": "high",
        "createdBy": "user-123"
    }
    """.data(using: .utf8)!

    // When: Decoding
    let spec = try JSONDecoder().decode(WorkerTaskSpec.self, from: json)

    // Then: Known fields decoded correctly
    #expect(spec.taskId == "task-123")
    #expect(spec.channelId == "channel-456")
    #expect(spec.title == "Test Task")
    #expect(spec.objective == "Test objective")
    #expect(spec.tools == ["tool1", "tool2"])
    #expect(spec.mode == .interactive)
}

@Test
func branchConclusionDecodesWithUnknownFields() throws {
    // Given: JSON with extra fields
    let json = """
    {
        "summary": "Task completed successfully",
        "artifactRefs": [],
        "memoryRefs": [],
        "tokenUsage": {"prompt": 100, "completion": 50},
        "duration": 1234,
        "cost": 0.05
    }
    """.data(using: .utf8)!

    // When: Decoding
    let conclusion = try JSONDecoder().decode(BranchConclusion.self, from: json)

    // Then: Known fields decoded correctly
    #expect(conclusion.summary == "Task completed successfully")
    #expect(conclusion.tokenUsage.prompt == 100)
    #expect(conclusion.tokenUsage.completion == 50)
    #expect(conclusion.artifactRefs.isEmpty)
    #expect(conclusion.memoryRefs.isEmpty)
}

@Test
func compactionJobDecodesWithUnknownFields() throws {
    // Given: JSON with extra fields
    let json = """
    {
        "id": "job-123",
        "channelId": "channel-456",
        "level": "aggressive",
        "threshold": 0.8,
        "createdAt": "2026-03-04T07:00:00Z",
        "priority": 1,
        "retryCount": 0
    }
    """.data(using: .utf8)!

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    // When: Decoding
    let job = try decoder.decode(CompactionJob.self, from: json)

    // Then: Known fields decoded correctly
    #expect(job.id == "job-123")
    #expect(job.channelId == "channel-456")
    #expect(job.level == .aggressive)
    #expect(job.threshold == 0.8)
}

@Test
func memoryBulletinDecodesWithUnknownFields() throws {
    // Given: JSON with extra fields
    let json = """
    {
        "id": "bulletin-123",
        "generatedAt": "2026-03-04T07:00:00Z",
        "headline": "Important Update",
        "digest": "Summary of events",
        "items": ["item1", "item2"],
        "category": "general",
        "tags": ["tag1"]
    }
    """.data(using: .utf8)!

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    // When: Decoding
    let bulletin = try decoder.decode(MemoryBulletin.self, from: json)

    // Then: Known fields decoded correctly
    #expect(bulletin.id == "bulletin-123")
    #expect(bulletin.headline == "Important Update")
    #expect(bulletin.digest == "Summary of events")
    #expect(bulletin.items == ["item1", "item2"])
}

// MARK: - APIModels Compatibility

@Test
func channelMessageRequestDecodesWithUnknownFields() throws {
    // Given: JSON with extra fields
    let json = """
    {
        "userId": "user-123",
        "content": "Hello world",
        "topicId": "topic-456",
        "metadata": {"key": "value"},
        "timestamp": 1700000000
    }
    """.data(using: .utf8)!

    // When: Decoding
    let request = try JSONDecoder().decode(ChannelMessageRequest.self, from: json)

    // Then: Known fields decoded correctly
    #expect(request.userId == "user-123")
    #expect(request.content == "Hello world")
    #expect(request.topicId == "topic-456")
}

@Test
func channelMessageRequestDecodesWithoutOptionalTopicId() throws {
    // Given: JSON without optional topicId
    let json = """
    {
        "userId": "user-123",
        "content": "Hello world"
    }
    """.data(using: .utf8)!

    // When: Decoding
    let request = try JSONDecoder().decode(ChannelMessageRequest.self, from: json)

    // Then: Optional field is nil
    #expect(request.userId == "user-123")
    #expect(request.content == "Hello world")
    #expect(request.topicId == nil)
}

@Test
func workerCreateRequestDecodesWithUnknownFields() throws {
    // Given: JSON with extra fields in nested spec
    let json = """
    {
        "spec": {
            "taskId": "task-123",
            "channelId": "channel-456",
            "title": "Test Task",
            "objective": "Test objective",
            "tools": ["tool1"],
            "mode": "fire_and_forget",
            "priority": "high"
        },
        "callbackUrl": "https://example.com/callback",
        "retryPolicy": {"maxRetries": 3}
    }
    """.data(using: .utf8)!

    // When: Decoding
    let request = try JSONDecoder().decode(WorkerCreateRequest.self, from: json)

    // Then: Known fields decoded correctly
    #expect(request.spec.taskId == "task-123")
    #expect(request.spec.mode == .fireAndForget)
}

@Test
func channelEventsResponseDecodesWithUnknownFields() throws {
    // Given: JSON with extra fields
    let json = """
    {
        "channelId": "channel-123",
        "items": [],
        "nextCursor": "cursor-456",
        "totalCount": 100,
        "hasMore": true
    }
    """.data(using: .utf8)!

    // When: Decoding
    let response = try JSONDecoder().decode(ChannelEventsResponse.self, from: json)

    // Then: Known fields decoded correctly
    #expect(response.channelId == "channel-123")
    #expect(response.items.isEmpty)
    #expect(response.nextCursor == "cursor-456")
}

@Test
func systemLogEntryDecodesWithUnknownFields() throws {
    // Given: JSON with extra fields
    let json = """
    {
        "timestamp": "2026-03-04T07:00:00Z",
        "level": "info",
        "label": "test-label",
        "message": "Test message",
        "source": "test-source",
        "metadata": {"key": "value"},
        "threadId": "thread-123",
        "correlationId": "corr-456"
    }
    """.data(using: .utf8)!

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    // When: Decoding
    let entry = try decoder.decode(SystemLogEntry.self, from: json)

    // Then: Known fields decoded correctly
    #expect(entry.level == .info)
    #expect(entry.label == "test-label")
    #expect(entry.message == "Test message")
    #expect(entry.source == "test-source")
    #expect(entry.metadata["key"] == "value")
}

@Test
func projectTaskDecodesWithUnknownFields() throws {
    // Given: JSON with extra fields
    let json = """
    {
        "id": "task-123",
        "title": "Test Task",
        "description": "Test description",
        "priority": "high",
        "status": "in_progress",
        "actorId": "actor-456",
        "teamId": "team-789",
        "claimedActorId": null,
        "claimedAgentId": null,
        "createdAt": "2026-03-04T07:00:00Z",
        "updatedAt": "2026-03-04T07:00:00Z",
        "tags": ["tag1", "tag2"],
        "dueDate": "2026-03-10T07:00:00Z"
    }
    """.data(using: .utf8)!

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    // When: Decoding
    let task = try decoder.decode(ProjectTask.self, from: json)

    // Then: Known fields decoded correctly
    #expect(task.id == "task-123")
    #expect(task.title == "Test Task")
    #expect(task.priority == "high")
    #expect(task.status == "in_progress")
    #expect(task.actorId == "actor-456")
}

@Test
func channelPluginRecordDecodesWithUnknownFields() throws {
    // Given: JSON with extra fields
    let json = """
    {
        "id": "plugin-123",
        "type": "telegram",
        "baseUrl": "https://api.telegram.org",
        "channelIds": ["channel-1", "channel-2"],
        "config": {"token": "secret"},
        "enabled": true,
        "deliveryMode": "http",
        "createdAt": "2026-03-04T07:00:00Z",
        "updatedAt": "2026-03-04T07:00:00Z",
        "version": "1.2.3",
        "capabilities": ["read", "write"]
    }
    """.data(using: .utf8)!

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    // When: Decoding
    let plugin = try decoder.decode(ChannelPluginRecord.self, from: json)

    // Then: Known fields decoded correctly
    #expect(plugin.id == "plugin-123")
    #expect(plugin.type == "telegram")
    #expect(plugin.deliveryMode == "http")
    #expect(plugin.channelIds == ["channel-1", "channel-2"])
}

// MARK: - JSONValue Compatibility

@Test
func jsonValueHandlesNestedUnknownStructures() throws {
    // Given: Complex nested JSON with various types
    let json = """
    {
        "string": "value",
        "number": 42.5,
        "integer": 100,
        "bool": true,
        "null": null,
        "array": [1, 2, 3, "mixed"],
        "nested": {
            "deep": {
                "value": "found"
            }
        },
        "unknownFutureField": {
            "complex": ["structure", 123, true]
        }
    }
    """.data(using: .utf8)!

    // When: Decoding to JSONValue
    let value = try JSONDecoder().decode(JSONValue.self, from: json)

    // Then: All values are preserved
    guard case .object(let dict) = value else {
        Issue.record("Expected object")
        return
    }

    #expect(dict["string"]?.asString == "value")
    #expect(dict["number"]?.asNumber == 42.5)
    #expect(dict["bool"]?.asBool == true)

    guard case .object(let nested) = dict["nested"] else {
        Issue.record("Expected nested object")
        return
    }

    guard case .object(let deep) = nested["deep"] else {
        Issue.record("Expected deep object")
        return
    }

    #expect(deep["value"]?.asString == "found")
}

// MARK: - JSONValueCoder Compatibility

@Test
func jsonValueCoderRoundTripWithUnknownFields() throws {
    // Given: A struct with extra fields encoded as JSONValue
    struct TestPayload: Codable {
        let knownField: String
        // Note: In real scenario, future versions might add fields
    }

    let payload = TestPayload(knownField: "test")
    let value = try JSONValueCoder.encode(payload)

    // When: Adding extra fields manually (simulating future schema)
    guard case .object(var dict) = value else {
        Issue.record("Expected object")
        return
    }
    dict["futureField"] = .string("future value")
    dict["futureNumber"] = .number(999)

    let modifiedValue = JSONValue.object(dict)

    // Then: Original fields are preserved, new fields accessible via JSONValue
    let decoded = try JSONValueCoder.decode(TestPayload.self, from: modifiedValue)
    #expect(decoded.knownField == "test")

    // Future fields are accessible in the JSONValue but ignored during decode
    #expect(dict["futureField"]?.asString == "future value")
    #expect(dict["futureNumber"]?.asNumber == 999)
}

// MARK: - Enum Compatibility

@Test
func messageTypeHandlesAllKnownCases() throws {
    // Given: All known message types
    let knownTypes: [MessageType] = [
        .channelMessageReceived,
        .channelRouteDecided,
        .branchSpawned,
        .branchConclusion,
        .workerSpawned,
        .workerProgress,
        .workerCompleted,
        .workerFailed,
        .compactorThresholdHit,
        .compactorSummaryApplied,
        .visorBulletinGenerated,
        .actorDiscussionStarted,
        .actorDiscussionConcluded
    ]

    // Then: All cases have valid raw values
    for type in knownTypes {
        #expect(!type.rawValue.isEmpty)
    }
}

@Test
func routeActionDecodesAllCases() throws {
    // Given: All route action raw values
    let respond = try JSONDecoder().decode(RouteAction.self, from: "\"respond\"".data(using: .utf8)!)
    let spawnBranch = try JSONDecoder().decode(RouteAction.self, from: "\"spawn_branch\"".data(using: .utf8)!)
    let spawnWorker = try JSONDecoder().decode(RouteAction.self, from: "\"spawn_worker\"".data(using: .utf8)!)

    // Then: All decode correctly
    #expect(respond == .respond)
    #expect(spawnBranch == .spawnBranch)
    #expect(spawnWorker == .spawnWorker)
}

@Test
func workerModeDecodesAllCases() throws {
    // Given: All worker mode raw values
    let fireAndForget = try JSONDecoder().decode(WorkerMode.self, from: "\"fire_and_forget\"".data(using: .utf8)!)
    let interactive = try JSONDecoder().decode(WorkerMode.self, from: "\"interactive\"".data(using: .utf8)!)

    // Then: All decode correctly
    #expect(fireAndForget == .fireAndForget)
    #expect(interactive == .interactive)
}

@Test
func compactionLevelDecodesAllCases() throws {
    // Given: All compaction level raw values
    let soft = try JSONDecoder().decode(CompactionLevel.self, from: "\"soft\"".data(using: .utf8)!)
    let aggressive = try JSONDecoder().decode(CompactionLevel.self, from: "\"aggressive\"".data(using: .utf8)!)
    let emergency = try JSONDecoder().decode(CompactionLevel.self, from: "\"emergency\"".data(using: .utf8)!)

    // Then: All decode correctly
    #expect(soft == .soft)
    #expect(aggressive == .aggressive)
    #expect(emergency == .emergency)
}

// MARK: - Forward Compatibility Documentation Tests
// These tests document expected behavior for future schema evolution

@Test
func forwardCompatibilityNotes() {
    // This test serves as documentation for forward compatibility expectations:
    //
    // 1. ADDING NEW OPTIONAL FIELDS: Safe
    //    - New optional fields can be added to existing models
    //    - Old clients will ignore them (Swift's synthesized Codable behavior)
    //    - New clients can check for presence using optional binding
    //
    // 2. ADDING NEW REQUIRED FIELDS: Breaking change
    //    - Requires major version bump
    //    - Old clients will fail to decode
    //
    // 3. REMOVING FIELDS: Breaking change
    //    - Old clients may depend on those fields
    //    - Consider deprecating first, then removing in major version
    //
    // 4. CHANGING FIELD TYPES: Breaking change
    //    - Even if compatible (e.g., Int to Double), it's risky
    //
    // 5. ADDING NEW ENUM CASES: Requires care
    //    - Swift will throw on unknown enum cases by default
    //    - Consider using @unknown default or string-backed enums with fallbacks
    //
    // 6. JSONValue as payload type: Maximum flexibility
    //    - Using JSONValue for payload/extensions allows any structure
    //    - Future fields can be nested in extensions dictionary
    //
    // Current behavior verification:
    #expect(Bool(true)) // Test always passes, serves as documentation
}

// MARK: - Complex Nested Compatibility

@Test
func complexNestedStructureWithUnknownFields() throws {
    // Given: ChannelEventsResponse with envelopes containing unknown fields
    let json = """
    {
        "channelId": "test-channel",
        "items": [
            {
                "protocolVersion": "1.0",
                "messageId": "msg-1",
                "messageType": "worker.progress",
                "ts": "2026-03-04T07:00:00Z",
                "traceId": "trace-1",
                "channelId": "test-channel",
                "payload": {"progress": 50},
                "extensions": {},
                "futureField": "future value"
            }
        ],
        "nextCursor": "cursor-1",
        "totalItems": 1,
        "pagination": {"limit": 100}
    }
    """.data(using: .utf8)!

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    // When: Decoding
    let response = try decoder.decode(ChannelEventsResponse.self, from: json)

    // Then: Structure decoded correctly with unknown fields ignored
    #expect(response.channelId == "test-channel")
    #expect(response.items.count == 1)
    #expect(response.items[0].messageId == "msg-1")
    #expect(response.nextCursor == "cursor-1")
}

@Test
func artifactRefDecodesWithUnknownFields() throws {
    // Given: JSON with extra fields
    let json = """
    {
        "id": "artifact-123",
        "kind": "file",
        "preview": "file.txt",
        "size": 1024,
        "mimeType": "text/plain"
    }
    """.data(using: .utf8)!

    // When: Decoding
    let ref = try JSONDecoder().decode(ArtifactRef.self, from: json)

    // Then: Known fields decoded correctly
    #expect(ref.id == "artifact-123")
    #expect(ref.kind == "file")
    #expect(ref.preview == "file.txt")
}

@Test
func memoryRefDecodesWithUnknownFields() throws {
    // Given: JSON with extra fields
    let json = """
    {
        "id": "memory-123",
        "score": 0.95,
        "timestamp": 1700000000,
        "source": "user"
    }
    """.data(using: .utf8)!

    // When: Decoding
    let ref = try JSONDecoder().decode(MemoryRef.self, from: json)

    // Then: Known fields decoded correctly
    #expect(ref.id == "memory-123")
    #expect(ref.score == 0.95)
}

@Test
func tokenUsageDecodesWithUnknownFields() throws {
    // Given: JSON with extra fields
    let json = """
    {
        "prompt": 1000,
        "completion": 500,
        "total": 1500,
        "cost": 0.003
    }
    """.data(using: .utf8)!

    // When: Decoding
    let usage = try JSONDecoder().decode(TokenUsage.self, from: json)

    // Then: Known fields decoded correctly, total computed correctly
    #expect(usage.prompt == 1000)
    #expect(usage.completion == 500)
    #expect(usage.total == 1500)
}
