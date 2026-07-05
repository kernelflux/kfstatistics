// ──────────────────────────────────────────────
//  BatchEvent — wire-format batch model
//  Mirrors event_schema.proto for the on-wire
//  representation.
// ──────────────────────────────────────────────

import Foundation

// ═══════════════════════════════════════════════
//  MARK: - StatisticsRecord
// ═══════════════════════════════════════════════

/// A single event in its wire format.
public struct StatisticsRecord: Sendable, Codable {
    public var eventID: String
    public var eventName: String
    public var schemaVersion: UInt32
    public var timestampMs: UInt64
    public var sessionID: String
    public var userID: String
    public var priority: UInt32
    /// Opaque payload bytes.
    public var payload: Data
    /// Field metadata for deserializing `payload`.
    public var fields: [FieldDescriptor]

    public init(
        eventID: String,
        eventName: String,
        schemaVersion: UInt32,
        timestampMs: UInt64,
        sessionID: String,
        userID: String,
        priority: UInt32,
        payload: Data,
        fields: [FieldDescriptor]
    ) {
        self.eventID = eventID
        self.eventName = eventName
        self.schemaVersion = schemaVersion
        self.timestampMs = timestampMs
        self.sessionID = sessionID
        self.userID = userID
        self.priority = priority
        self.payload = payload
        self.fields = fields
    }
}

// ═══════════════════════════════════════════════
//  MARK: - StatisticsBatch
// ═══════════════════════════════════════════════

/// A batch of events sent in one HTTP request.
public struct StatisticsBatch: Sendable, Codable {
    public var appVersion: String
    public var deviceID: String
    public var platform: String
    public var createdAt: UInt64
    public var events: [StatisticsRecord]

    public init(
        appVersion: String,
        deviceID: String,
        platform: String = "ios",
        createdAt: UInt64 = .now(),
        events: [StatisticsRecord]
    ) {
        self.appVersion = appVersion
        self.deviceID = deviceID
        self.platform = platform
        self.createdAt = createdAt
        self.events = events
    }
}

// ═══════════════════════════════════════════════
//  MARK: - BinarySerializable conformance
// ───────────────────────────────────────────────
//  BatchEvent uses the StatisticsBinarySerializer
//  internally; the outer batch wrapper can be
//  encoded via Codable → JSON for the HTTP body,
//  or we can use a full binary encoding.

extension StatisticsBatch {
    /// Encode the batch to compact JSON (UTF-8).
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Encode the batch to binary format (PropertyList binary).
    /// 2-3× smaller than JSON, no base64 expansion on Data fields.
    /// Used for on-disk Storage; Transport layer decides its own encoding.
    public func binaryData() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(self)
    }

    /// Decode a batch from binary format (PropertyList binary).
    public static func from(binaryData data: Data) throws -> StatisticsBatch {
        let decoder = PropertyListDecoder()
        return try decoder.decode(StatisticsBatch.self, from: data)
    }
}
