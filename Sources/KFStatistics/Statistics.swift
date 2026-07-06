// ──────────────────────────────────────────────
//  KFStatistics — Public SDK Entry Point
//
//  Usage:
//
//      1. Configure (once at app launch):
//          KFStatistics.configure {
//              config.endpoint = URL(string: "https://api.example.com/events")!
//              config.batchSize = 100
//          }
//
//      2. Start:
//          KFStatistics.start()
//
//      3. Track events:
//          KFStatistics.track(ButtonClick(buttonId: "btn_a", pageName: "home"))
//          KFStatistics.track("CustomEvent", ["key": "value"])
//
// ═══════════════════════════════════════════════

import Foundation
import os
@_exported import KFStatisticsCore
#if canImport(UIKit)
import UIKit
#endif

/// The top-level SDK object.
public enum KFStatistics {

    // ── Internal state (protected by OSAllocatedUnfairLock, iOS 16+) ──

    nonisolated(unsafe) private static var _config = StatisticsConfig()
    private static let _configLock = OSAllocatedUnfairLock()

    nonisolated(unsafe) private static var _pipeline: StatisticsPipeline?
    nonisolated(unsafe) private static var _dispatcher: StatisticsDispatcher?
    /// Always-on tracker for SwiftUI `.trackPage()` modifier.
    /// Created at module init — before any view renders — so
    /// the first `.onAppear` notification is never missed.
    private static let _pageTracker = StatisticsPageTracker()

    private static let _pipelineLock = OSAllocatedUnfairLock()

    /// Events tracked before `start()` — flushed once the pipeline is ready.
    nonisolated(unsafe) private static var _pendingEvents: [DynamicEvent] = []
    private static let _pendingLock = OSAllocatedUnfairLock()

    // ────────────────────────────────────────────
    //  MARK: - Configuration
    // ────────────────────────────────────────────

    /// Configure the SDK.  Must be called once before `start()`.
    public static func configure(_ changes: (inout StatisticsConfig) -> Void) {
        _configLock.lock()
        _config.apply(changes)
        _configLock.unlock()
    }

    public static var configuration: StatisticsConfig {
        _configLock.lock()
        defer { _configLock.unlock() }
        return _config
    }

    // ────────────────────────────────────────────
    //  MARK: - Preload (eager init)
    // ────────────────────────────────────────────

    /// Force initialization of static storage before any view renders.
    /// Call this from `KFStatisticsAssembly.assemble()` (which runs in `App.init()`)
    /// so that `_pageTracker` is ready before the first `.onAppear` fires.
    public static func preload() {
        _ = _pageTracker
    }

    // ────────────────────────────────────────────
    //  MARK: - Lifecycle
    // ────────────────────────────────────────────

    /// Start the SDK.  Call once after `configure()`.
    public static func start() {
        _pipelineLock.lock()
        let alreadyStarted = (_pipeline != nil)
        if !alreadyStarted {
            let config = configuration
            let useStorage = StatisticsFileStorage()
            let useSerializer = StatisticsBinarySerializer()
            let pipeline = StatisticsPipeline(storage: useStorage, serializer: useSerializer, config: config)
            let transport = makeTransport(from: config)
            let dispatcher = StatisticsDispatcher(storage: useStorage, transport: transport, config: config)
            _pipeline = pipeline
            _dispatcher = dispatcher
            _pipelineLock.unlock()

            startAutoTracking(with: config)

            Task(priority: .utility) {
                await dispatcher.start()
            }

            subscribeToAppLifecycleNotifications()

            // Flush any events that were tracked before start()
            let pending = _pendingLock.withLock {
                let q = _pendingEvents
                _pendingEvents = []
                return q
            }
            if !pending.isEmpty {
                Task(priority: .utility) {
                    for event in pending {
                        try? await pipeline.track(event)
                    }
                }
            }
        } else {
            _pipelineLock.unlock()
        }
    }

    // ────────────────────────────────────────────
    //  MARK: - Transport factory
    // ────────────────────────────────────────────

    private static func makeTransport(from config: StatisticsConfig) -> any StatisticsTransport {
        // 优先级 1：uploadHandler 闭包（简单场景）
        if let handler = config.uploadHandler { return HandlerTransport(handler: handler) }
        // 优先级 2：Transport 协议（高级场景）
        if let custom = config.transport { return custom }

        var httpConfig: StatisticsHTTPTransportConfig
        if let explicit = config.httpConfig {
            httpConfig = explicit
        } else if let endpoint = config.endpoint {
            httpConfig = StatisticsHTTPTransportConfig(baseURL: endpoint)
        } else {
            httpConfig = StatisticsHTTPTransportConfig(
                baseURL: URL(string: "https://localhost:8080/events")!
            )
        }

        if let method = config.httpMethod { httpConfig.method = method }
        if let headers = config.httpHeaders {
            for (key, value) in headers { httpConfig.headers[key] = value }
        }

        return StatisticsHTTPTransport(config: httpConfig)
    }

    /// 将上传闭包包装为 Transport 协议。
    private struct HandlerTransport: StatisticsTransport {
        let handler: StatisticsUploadHandler
        func send(batch: StatisticsBatch) async throws -> Int {
            try await handler(batch)
        }
    }

    // ────────────────────────────────────────────
    //  MARK: - Foreground / Background
    // ────────────────────────────────────────────

    private static func subscribeToAppLifecycleNotifications() {
        #if canImport(UIKit)
        Task { @MainActor in
            NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil, queue: .main
            ) { _ in
                Task(priority: .utility) { await _dispatcher?.onForegroundChange(true) }
            }
            NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil, queue: .main
            ) { _ in
                Task(priority: .utility) { await _dispatcher?.onForegroundChange(false) }
            }
        }
        #endif
    }

    // ────────────────────────────────────────────
    //  MARK: - Auto tracking
    // ────────────────────────────────────────────

    private static func startAutoTracking(with config: StatisticsConfig) {
        #if canImport(UIKit)
        if config.enableAutoPageTracking {
            UIViewController.enablePageAutoTracking()
        }
        #endif
    }

    // ────────────────────────────────────────────
    //  MARK: - Shutdown
    // ────────────────────────────────────────────

    public static func shutdown() async {
        let (dispatcher, pipeline) = clearInstances()
        await dispatcher?.stop()
        try? await pipeline?.flushToStorage()
    }

    #if DEBUG
    /// Reset SDK state for test isolation.
    public static func reset() {
        _pipelineLock.lock()
        _pipeline = nil
        _dispatcher = nil
        _config = StatisticsConfig()
        _pipelineLock.unlock()
        _pendingLock.lock()
        _pendingEvents = []
        _pendingLock.unlock()
    }
    #endif

    private static func clearInstances() -> (StatisticsDispatcher?, StatisticsPipeline?) {
        _pipelineLock.lock()
        let d = _dispatcher
        let p = _pipeline
        _dispatcher = nil
        _pipeline = nil
        _pipelineLock.unlock()
        return (d, p)
    }

    // ────────────────────────────────────────────
    //  MARK: - Tracking API
    // ────────────────────────────────────────────

    public static func track<E: EventProtocol>(_ event: E) {
        let pipeline = readPipeline()
        guard let pipeline else {
            // Pipeline not ready yet — queue for flush on start()
            if let dyn = event as? DynamicEvent {
                _pendingLock.lock()
                _pendingEvents.append(dyn)
                _pendingLock.unlock()
            }
            return
        }
        Task(priority: .utility) { try? await pipeline.track(event) }
    }

    public static func track(
        _ name: String,
        _ properties: [String: StatisticsValue] = [:],
        priority: StatisticsPriority = .default
    ) {
        let event = DynamicEvent(name: name, properties: properties, priority: priority)
        track(event as DynamicEvent)
    }

    public static func track(
        _ name: String,
        _ values: [String: any Sendable],
        priority: StatisticsPriority = .default
    ) {
        let properties = values.compactMapValues { value -> StatisticsValue? in
            switch value {
            case let v as String:   return .string(v)
            case let v as Int64:    return .int64(v)
            case let v as Int:      return .int64(Int64(v))
            case let v as UInt64:   return .uint64(v)
            case let v as Double:   return .double(v)
            case let v as Bool:     return .bool(v)
            case let v as Data:     return .data(v)
            default:                return nil
            }
        }
        track(name, properties, priority: priority)
    }

    // ────────────────────────────────────────────
    //  MARK: - Internal
    // ────────────────────────────────────────────

    private static func readPipeline() -> StatisticsPipeline? {
        _pipelineLock.lock()
        let p = _pipeline
        _pipelineLock.unlock()
        return p
    }
}
