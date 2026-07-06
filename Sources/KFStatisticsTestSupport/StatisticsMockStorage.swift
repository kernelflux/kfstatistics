// ──────────────────────────────────────────────
//  StatisticsMockStorage — for unit tests
//  An in-memory StatisticsStorage implementation
//  that does not touch the file system.
// ──────────────────────────────────────────────

import Foundation
@testable import KFStatistics

/// In-memory storage for testing.  No files, no I/O.
public final actor StatisticsMockStorage: StatisticsStorage {

    public private(set) var estimatedByteCount: UInt64 = 0
    private var store: [String: Data] = [:]

    public init() {}

    public func append(_ data: Data, forKey key: String) async throws {
        var existing = store[key] ?? Data()
        existing.append(data)
        store[key] = existing
        estimatedByteCount += UInt64(data.count)
    }

    public func popAll(forKey key: String) async throws -> [Data] {
        guard let data = store[key] else { return [] }
        store[key] = nil
        estimatedByteCount = 0
        return [data]
    }

    public func flush() async throws {}

    public func clear() async throws {
        store.removeAll()
        estimatedByteCount = 0
    }

    /// Total events stored (each is one popAll frame).
    public var eventCount: Int {
        store.values.reduce(0) { $0 + $1.count }
    }
}
