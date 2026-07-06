// ──────────────────────────────────────────────
//  StatisticsStorage
//
//  Abstraction over the event storage backend.
//  Ships with two implementations:
//    1. StatisticsMMKVStorage  — fastest (mmap)
//    2. StatisticsFileStorage — pure Swift fallback
// ──────────────────────────────────────────────

import Foundation

// ═══════════════════════════════════════════════
//  MARK: - StorageError
// ═══════════════════════════════════════════════

public enum EventStorageError: Error, Sendable {
    case writeFailed(String)
    case readFailed(String)
    case corruptData(String)
    case storageFull
}

// ═══════════════════════════════════════════════
//  MARK: - Storage Protocol
// ═══════════════════════════════════════════════

/// A thread-safe key-value storage abstraction
/// optimised for append-only event logs.
protocol StatisticsStorage: Actor {

    /// The total byte count stored.
    var estimatedByteCount: UInt64 { get }

    /// Append raw bytes to the log identified by `key`.
    func append(_ data: Data, forKey key: String) async throws

    /// Atomically read **and clear** all data for `key`.
    /// Returns an array of individual batch payloads (one per frame).
    func popAll(forKey key: String) async throws -> [Data]

    /// Persist pending writes to disk.
    func flush() async throws

    /// Remove all stored data.
    func clear() async throws
}
