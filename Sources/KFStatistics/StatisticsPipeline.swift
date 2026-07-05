// ──────────────────────────────────────────────
//  StatisticsPipeline — the heart of the SDK.
//
//  An actor that:
//    1. Receives concrete events via track(_:)
//    2. Wraps them as AnyEvent + serialises
//    3. Buffers in the StatisticsRingBuffer (transient)
//    4. Flushes to persistent storage per uploadMode
// ──────────────────────────────────────────────

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The primary event ingestion actor.
///
/// All `track()` calls are serialised on the
/// actor's executor — zero locks, zero data races.
final actor StatisticsPipeline {

    // ────────────────────────────────────────────
    //  MARK: - Dependencies
    // ────────────────────────────────────────────

    private let storage: any StatisticsStorage
    private let serializer: any StatisticsSerializer
    private let config: StatisticsConfig
    private let ringBuffer: StatisticsRingBuffer

    // ────────────────────────────────────────────
    //  MARK: - State
    // ────────────────────────────────────────────

    private var eventCount: UInt64 = 0
    private var lastFlushTime: Date = Date()

    // ────────────────────────────────────────────
    //  MARK: - Init
    // ────────────────────────────────────────────

    init(
        storage: any StatisticsStorage,
        serializer: any StatisticsSerializer = StatisticsBinarySerializer(),
        config: StatisticsConfig = .init()
    ) {
        self.storage = storage
        self.serializer = serializer
        self.config = config
        self.ringBuffer = StatisticsRingBuffer(capacity: max(config.uploadThreshold, 10) * 2)
    }

    // ────────────────────────────────────────────
    //  MARK: - Public API
    // ────────────────────────────────────────────

    /// Track a single event.
    func track<E: EventProtocol>(_ event: E) async throws {
        var mutableEvent = event
        mutableEvent.sessionID = config.sessionID
        mutableEvent.eventID = UUID()

        let anyEvent = try AnyEvent(mutableEvent, serializer: serializer)
        ringBuffer.enqueue(anyEvent)
        pendingEventCount = ringBuffer.count
        eventCount += 1

        try await evaluateFlush()
    }

    /// Flush the in-memory buffer to persistent storage immediately.
    func flushToStorage() async throws {
        let events = ringBuffer.dequeueAll()
        guard !events.isEmpty else { return }
        pendingEventCount = 0

        let records = events.map { event in
            StatisticsRecord(
                eventID: event.eventID.uuidString,
                eventName: event.eventName,
                schemaVersion: event.schemaVersion,
                timestampMs: event.timestampMs,
                sessionID: event.sessionID,
                userID: config.userID,
                priority: event.priority.rawValue,
                payload: event.serializedPayload,
                fields: event.fields
            )
        }

        let batch = StatisticsBatch(
            appVersion: Self.appVersion,
            deviceID: Self.deviceID,
            platform: Self.platform,
            events: records
        )

        let data = try batch.binaryData()
        try await storage.append(data, forKey: walKey)
        lastFlushTime = Date()
    }

    private(set) nonisolated(unsafe) var pendingEventCount: Int = 0

    // ────────────────────────────────────────────
    //  MARK: - Upload mode evaluation
    // ────────────────────────────────────────────

    /// 根据 uploadMode 决定是否 flush 到 storage。
    private func evaluateFlush() async throws {
        switch config.uploadMode {

        case .always:
            // 每次事件立即 flush（实时性最高，网络请求最频繁）
            try await flushToStorage()

        case .batchThreshold:
            // 达到阈值才 flush
            if ringBuffer.count >= config.uploadThreshold {
                try await flushToStorage()
            }

        case .interval:
            // 按时间间隔 flush
            if hasTimedOut {
                try await flushToStorage()
            }

        case .intelligent:
            // 智能模式：阈值或间隔，先到者触发
            if ringBuffer.count >= config.uploadThreshold || hasTimedOut {
                try await flushToStorage()
            }
        }
    }

    // ────────────────────────────────────────────
    //  MARK: - Private helpers
    // ────────────────────────────────────────────

    private var hasTimedOut: Bool {
        Date().timeIntervalSince(lastFlushTime) > config.uploadInterval
    }

    private var walKey: String { "events_wal" }

    // ── Static constants ──

    nonisolated(unsafe) private static let appVersion: String = {
        unsafeAppVersion()
    }()

    nonisolated(unsafe) private static let deviceID: String = {
        #if canImport(UIKit) && !os(watchOS) && !os(visionOS)
        unsafeDeviceID()
        #elseif os(watchOS)
        return "watch_\(Self.appVersion)"
        #elseif os(macOS)
        let key = "com.kfargus.deviceID"
        if let stored = UserDefaults.standard.string(forKey: key) { return stored }
        let newID = "mac_\(UUID().uuidString.prefix(8))"
        UserDefaults.standard.set(newID, forKey: key)
        return newID
        #else
        return "unknown"
        #endif
    }()

    nonisolated(unsafe) private static func unsafeAppVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    #if canImport(UIKit) && !os(watchOS) && !os(visionOS)
    nonisolated(unsafe) private static func unsafeDeviceID() -> String {
        UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
    }
    #endif

    private static let platform: String = {
        #if os(iOS)
        return "ios"
        #elseif os(tvOS)
        return "tvos"
        #elseif os(watchOS)
        return "watchos"
        #elseif os(visionOS)
        return "visionos"
        #elseif os(macOS)
        return "macos"
        #else
        return "unknown"
        #endif
    }()
}
