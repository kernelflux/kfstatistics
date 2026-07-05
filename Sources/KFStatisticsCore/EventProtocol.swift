// ──────────────────────────────────────────────
//  EventProtocol
//  Every tracked event type conforms to this
//  protocol.  The @Trackable macro auto-synthesises
//  conformance at compile time.
// ──────────────────────────────────────────────

import Foundation

// ═══════════════════════════════════════════════
//  MARK: - Event Metadata
// ═══════════════════════════════════════════════

/// Describes a single field of an event for binary serialisation.
public struct FieldDescriptor: Sendable, Equatable, Codable {
    public let name: String
    public let type: FieldType

    public init(name: String, type: FieldType) {
        self.name = name
        self.type = type
    }
}

/// Supported scalar field types for the binary encoder.
public enum FieldType: Sendable, Equatable, Codable {
    case string
    case int64
    case uint64
    case double
    case bool
    case data
}

/// Event priority — controls dispatch urgency.
public enum StatisticsPriority: UInt32, Sendable, Comparable {
    case background = 0
    case `default` = 1
    case critical  = 2

    public static func < (lhs: StatisticsPriority, rhs: StatisticsPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// ═══════════════════════════════════════════════
//  MARK: - Event Protocol
// ═══════════════════════════════════════════════

/// Every event **must** conform to this protocol.
///
/// The `@Trackable` macro automatically adds
/// conformance — you normally do **not** adopt
/// this manually.
public protocol EventProtocol: Sendable, Codable {
    var eventName: String { get }
    static var schemaVersion: UInt32 { get }
    var fields: [FieldDescriptor] { get }

    var eventID: UUID { get set }
    var timestampMs: UInt64 { get set }
    var sessionID: String { get set }
    var priority: StatisticsPriority { get }
}

extension EventProtocol {
    public var priority: StatisticsPriority { .default }
}

// ═══════════════════════════════════════════════
//  MARK: - DynamicEvent
//
//  A flexible dictionary-backed event for ad-hoc
//  tracking without a predefined @Trackable struct.
//
//  Usage:
//      KFStatistics.track("Purchase", [
//          "itemID":  .string("sku_123"),
//          "price":   .double(29.99),
//      ])
// ═══════════════════════════════════════════════

public struct DynamicEvent: Sendable, EventProtocol {

    public var eventName: String { name }
    public static let schemaVersion: UInt32 = 1
    public var fields: [FieldDescriptor] {
        properties.map { (key, value) in
            FieldDescriptor(name: key, type: value.fieldType)
        }
    }

    public var eventID: UUID
    public var timestampMs: UInt64
    public var sessionID: String
    public var priority: StatisticsPriority

    public let name: String
    public let properties: [String: StatisticsValue]

    public init(
        name: String,
        properties: [String: StatisticsValue] = [:],
        priority: StatisticsPriority = .default,
        eventID: UUID = .init(),
        timestampMs: UInt64 = .now(),
        sessionID: String = ""
    ) {
        self.name = name
        self.properties = properties
        self.priority = priority
        self.eventID = eventID
        self.timestampMs = timestampMs
        self.sessionID = sessionID
    }

    // ── Manual Codable (properties are [String: StatisticsValue]) ──
    enum CodingKeys: String, CodingKey {
        case name, properties, priority, eventID, timestampMs, sessionID
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(properties, forKey: .properties)
        try container.encode(priority.rawValue, forKey: .priority)
        try container.encode(eventID, forKey: .eventID)
        try container.encode(timestampMs, forKey: .timestampMs)
        try container.encode(sessionID, forKey: .sessionID)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.properties = try container.decode([String: StatisticsValue].self, forKey: .properties)
        let rawPriority = try container.decode(UInt32.self, forKey: .priority)
        self.priority = StatisticsPriority(rawValue: rawPriority) ?? .default
        self.eventID = try container.decode(UUID.self, forKey: .eventID)
        self.timestampMs = try container.decode(UInt64.self, forKey: .timestampMs)
        self.sessionID = try container.decode(String.self, forKey: .sessionID)
    }
}

// ═══════════════════════════════════════════════
//  MARK: - StatisticsValue
// ═══════════════════════════════════════════════

public enum StatisticsValue: Sendable, Codable {
    case string(String)
    case int64(Int64)
    case uint64(UInt64)
    case double(Double)
    case bool(Bool)
    case data(Data)

    public var fieldType: FieldType {
        switch self {
        case .string: return .string
        case .int64: return .int64
        case .uint64: return .uint64
        case .double: return .double
        case .bool: return .bool
        case .data: return .data
        }
    }

    // ── Manual Codable ──
    private enum CodingKey: String, Swift.CodingKey {
        case type, value
    }

    private enum ValueType: String, Codable {
        case string, int64, uint64, double, bool, data
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKey.self)
        switch self {
        case .string(let v):
            try container.encode(ValueType.string, forKey: .type)
            try container.encode(v, forKey: .value)
        case .int64(let v):
            try container.encode(ValueType.int64, forKey: .type)
            try container.encode(v, forKey: .value)
        case .uint64(let v):
            try container.encode(ValueType.uint64, forKey: .type)
            try container.encode(v, forKey: .value)
        case .double(let v):
            try container.encode(ValueType.double, forKey: .type)
            try container.encode(v, forKey: .value)
        case .bool(let v):
            try container.encode(ValueType.bool, forKey: .type)
            try container.encode(v, forKey: .value)
        case .data(let v):
            try container.encode(ValueType.data, forKey: .type)
            try container.encode(v.base64EncodedString(), forKey: .value)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKey.self)
        let type = try container.decode(ValueType.self, forKey: .type)
        switch type {
        case .string:
            self = .string(try container.decode(String.self, forKey: .value))
        case .int64:
            self = .int64(try container.decode(Int64.self, forKey: .value))
        case .uint64:
            self = .uint64(try container.decode(UInt64.self, forKey: .value))
        case .double:
            self = .double(try container.decode(Double.self, forKey: .value))
        case .bool:
            self = .bool(try container.decode(Bool.self, forKey: .value))
        case .data:
            let b64 = try container.decode(String.self, forKey: .value)
            guard let data = Data(base64Encoded: b64) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value, in: container,
                    debugDescription: "Invalid base64 data"
                )
            }
            self = .data(data)
        }
    }
}

// ═══════════════════════════════════════════════
//  MARK: - StatisticsValue convenience
// ═══════════════════════════════════════════════

extension StatisticsValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: StringLiteralType) { self = .string(value) }
}

extension StatisticsValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: IntegerLiteralType) {
        self = .int64(Int64(value))
    }
}

extension StatisticsValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: FloatLiteralType) { self = .double(value) }
}

extension StatisticsValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: BooleanLiteralType) { self = .bool(value) }
}

// ═══════════════════════════════════════════════
//  MARK: - Timestamp Helper
// ═══════════════════════════════════════════════

extension UInt64 {
    /// Returns the current wall-clock time in
    /// milliseconds since 1970-01-01.
    @inline(__always)
    public static func now() -> Self {
        UInt64(Date().timeIntervalSince1970 * 1000)
    }
}
