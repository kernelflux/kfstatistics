// ──────────────────────────────────────────────
//  AnyEvent — type-erased event wrapper
//  Used inside the pipeline so that heterogeneous
//  event types can live in the same buffer.
// ──────────────────────────────────────────────

import Foundation

/// A type-erased event that the pipeline can
/// store, serialise, and forward without knowing
/// the concrete type at runtime.
struct AnyEvent: Sendable {
    let eventID: UUID
    let eventName: String
    let schemaVersion: UInt32
    let timestampMs: UInt64
    let sessionID: String
    let priority: StatisticsPriority
    let fields: [FieldDescriptor]
    let serializedPayload: Data

    init<E: EventProtocol>(_ event: E, serializer: some StatisticsSerializer) throws {
        self.eventID = event.eventID
        self.eventName = event.eventName
        self.schemaVersion = E.schemaVersion
        self.timestampMs = event.timestampMs
        self.sessionID = event.sessionID
        self.priority = event.priority
        self.fields = event.fields
        self.serializedPayload = try serializer.serialize(event)
    }
}
