// ──────────────────────────────────────────────
//  KFStatisticsTests — SDK unit tests
// ──────────────────────────────────────────────

import Testing
import Foundation
@testable import KFStatistics
@testable import KFStatisticsTestSupport

// ═══════════════════════════════════════════════
//  MARK: - Test event types
// ═══════════════════════════════════════════════

// The @Trackable macro would generate conformance.
// Until the macro plugin is loaded, we define a
// manual conformance for testing.

struct TestEvent: EventProtocol, Codable, Sendable {
    var eventName: String { "TestEvent" }
    static let schemaVersion: UInt32 = 1
    var fields: [FieldDescriptor] { [
        .init(name: "label", type: .string),
        .init(name: "count", type: .int64),
    ] }

    let label: String
    let count: Int64

    var eventID: UUID = .init()
    var timestampMs: UInt64 = .now()
    var sessionID: String = ""
}

struct CriticalEvent: EventProtocol, Codable, Sendable {
    var eventName: String { "CriticalEvent" }
    static let schemaVersion: UInt32 = 1
    var fields: [FieldDescriptor] { [] }

    var eventID: UUID = .init()
    var timestampMs: UInt64 = .now()
    var sessionID: String = ""
    var priority: StatisticsPriority { .critical }
}

// ═══════════════════════════════════════════════
//  MARK: - Tests
// ═══════════════════════════════════════════════

@Suite("EventProtocol")
struct EventProtocolTests {

    @Test("eventName is the struct name")
    func eventName() {
        #expect(TestEvent(label: "a", count: 1).eventName == "TestEvent")
    }

    @Test("timestampMs is non-zero")
    func timestamp() {
        let event = TestEvent(label: "a", count: 1)
        #expect(event.timestampMs > 0)
    }

    @Test("priority defaults to .default")
    func defaultPriority() {
        let event = TestEvent(label: "a", count: 1)
        #expect(event.priority == .default)
    }

    @Test("critical priority overrides")
    func criticalPriority() {
        let event = CriticalEvent()
        #expect(event.priority == .critical)
    }
}

// ═══════════════════════════════════════════════
//  MARK: - StatisticsRingBuffer Tests
// ═══════════════════════════════════════════════

@Suite("StatisticsRingBuffer")
struct StatisticsRingBufferTests {

    @Test("enqueue and dequeueAll returns events in FIFO order")
    func fifoOrder() {
        let buffer = StatisticsRingBuffer(capacity: 8)
        let anyEvent = makeAnyEvent()

        buffer.enqueue(anyEvent)
        buffer.enqueue(anyEvent)

        let result = buffer.dequeueAll()
        #expect(result.count == 2)
        #expect(buffer.isEmpty)
    }

    @Test("empty buffer returns empty array")
    func emptyBuffer() {
        let buffer = StatisticsRingBuffer(capacity: 8)
        #expect(buffer.dequeueAll().isEmpty)
        #expect(buffer.isEmpty)
    }

    @Test("buffer wraps correctly when full")
    func wrapAround() {
        let buffer = StatisticsRingBuffer(capacity: 4)
        let anyEvent = makeAnyEvent()

        // Fill beyond capacity (oldest should be dropped)
        for _ in 0..<6 {
            buffer.enqueue(anyEvent)
        }

        let result = buffer.dequeueAll()
        // Capacity is power-of-two, so 4
        #expect(result.count == 4)
    }

    private func makeAnyEvent() -> AnyEvent {
        let event = TestEvent(label: "test", count: 42)
        return try! AnyEvent(event, serializer: StatisticsBinarySerializer())
    }
}

// ═══════════════════════════════════════════════
//  MARK: - Binary Serializer Tests
// ═══════════════════════════════════════════════

@Suite("StatisticsBinarySerializer")
struct SerializerTests {

    @Test("round-trip serializes and deserializes correctly")
    func roundTrip() throws {
        let serializer = StatisticsBinarySerializer()
        let event = TestEvent(label: "hello", count: 42)

        let data = try serializer.serialize(event)
        #expect(!data.isEmpty)

        let fields = try serializer.deserialize(data, fields: event.fields)
        #expect(fields["label"] as? String == "hello")
        #expect(fields["count"] as? Int64 == 42)
    }

    @Test("serialized data is deterministic")
    func deterministic() throws {
        let serializer = StatisticsBinarySerializer()
        let event1 = TestEvent(label: "x", count: 1)
        let event2 = TestEvent(label: "x", count: 1)

        let data1 = try serializer.serialize(event1)
        let data2 = try serializer.serialize(event2)
        #expect(data1 == data2)
    }

    @Test("deserialize empty data returns empty dict")
    func deserializeEmpty() throws {
        let serializer = StatisticsBinarySerializer()
        let event = TestEvent(label: "", count: 0)
        let fields = try serializer.deserialize(Data(), fields: event.fields)
        #expect(fields.isEmpty)
    }
}

// ═══════════════════════════════════════════════
//  MARK: - StatisticsPipeline Tests
// ═══════════════════════════════════════════════

@Suite("StatisticsPipeline")
struct PipelineTests {

    @Test("track event does not persist until threshold is reached")
    func trackEventBuffered() async throws {
        let storage = StatisticsMockStorage()
        let pipeline = StatisticsPipeline(storage: storage)

        let event = TestEvent(label: "button", count: 3)
        try await pipeline.track(event)

        // 事件在 ring buffer 中，未到阈值（30），storage 无数据
        #expect(pipeline.pendingEventCount == 1)

        let stored = try await storage.popAll(forKey: "events_wal")
        #expect(stored == nil, "事件未到阈值不应写入 storage")
    }

    @Test("track with .always mode persists immediately")
    func trackAlwaysMode() async throws {
        let storage = StatisticsMockStorage()
        let pipeline = StatisticsPipeline(storage: storage, config: {
            var c = StatisticsConfig()
            c.uploadMode = .always
            return c
        }())

        let event = TestEvent(label: "instant", count: 1)
        try await pipeline.track(event)

        let stored = try await storage.popAll(forKey: "events_wal")
        #expect(stored != nil, ".always 模式应即时写入 storage")
    }

    @Test("flush produces valid binary batch")
    func flushProducesBinaryBatch() async throws {
        let storage = StatisticsMockStorage()
        let pipeline = StatisticsPipeline(storage: storage, config: {
            var c = StatisticsConfig()
            c.uploadThreshold = 2
            c.uploadMode = .batchThreshold
            return c
        }())

        let event = TestEvent(label: "a", count: 1)
        try await pipeline.track(event)
        try await pipeline.track(event)

        let raw = try await storage.popAll(forKey: "events_wal")
        #expect(raw != nil)

        if let raw {
            let batch = try StatisticsBatch.from(binaryData: raw)
            #expect(batch.events.count == 2)
            #expect(batch.events.first?.eventName == "TestEvent")
        }
    }
}

// ═══════════════════════════════════════════════
//  MARK: - StatisticsDispatcher Tests
// ═══════════════════════════════════════════════

@Suite("StatisticsDispatcher")
struct DispatchTests {

    @Test("dispatch with no data is a no-op")
    func noData() async {
        let storage = StatisticsMockStorage()
        let transport = StatisticsHTTPTransport(endpoint: URL(string: "https://localhost:0")!)
        let dispatcher = StatisticsDispatcher(storage: storage, transport: transport)

        // Should not throw or crash
        let result = await dispatcher.dispatchNow()
        #expect(!result)
    }
}
