// ──────────────────────────────────────────────
//  StatisticsDispatcher — pulls events from storage
//  and sends them to the backend.
//
//  Runs on a **utility** QoS actor — never
//  competes with UI work.
//
//  4 种上报模式的 dispatch 逻辑：
//    .always        → 每次 storage 有数据就立即尝试上报
//    .batchThreshold→ 只检查阈值（由 Pipeline 控制）
//    .interval      → 定时唤醒上传
//    .intelligent   → interval + 前后台切换 + 阈值混合
// ──────────────────────────────────────────────

import Foundation

final actor StatisticsDispatcher {

    // ────────────────────────────────────────────
    //  MARK: - Dependencies & State
    // ────────────────────────────────────────────

    private let storage: any StatisticsStorage
    private let transport: any StatisticsTransport
    private let config: StatisticsConfig

    private var isUploading = false
    private var consecutiveFailures: Int = 0
    private var dispatchTask: Task<Void, Never>?
    private var isForeground = true

    // ────────────────────────────────────────────
    //  MARK: - Init
    // ────────────────────────────────────────────

    init(
        storage: any StatisticsStorage,
        transport: any StatisticsTransport,
        config: StatisticsConfig = .init()
    ) {
        self.storage = storage
        self.transport = transport
        self.config = config
    }

    // ────────────────────────────────────────────
    //  MARK: - Public API
    // ────────────────────────────────────────────

    func start() {
        dispatchTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.dispatchIfNeeded()
                // 根据 mode 决定轮询间隔
                let interval = await self.pollInterval
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stop() {
        dispatchTask?.cancel()
        dispatchTask = nil
    }

    /// 通知 dispatcher 前后台切换（.intelligent 模式使用）。
    func onForegroundChange(_ isForeground: Bool) async {
        self.isForeground = isForeground
        if isForeground && config.uploadMode == .intelligent {
            // 回前台 → 立即尝试上报残留数据
            await dispatchIfNeeded()
        }
        if !isForeground && config.uploadMode == .intelligent {
            // 进后台 → 立即 flush 所有数据
            await dispatchNow()
        }
    }

    @discardableResult
    func dispatchNow() async -> Bool {
        await dispatchIfNeeded()
    }

    // ────────────────────────────────────────────
    //  MARK: - Poll interval per mode
    // ────────────────────────────────────────────

    /// 后台轮询间隔（秒），根据 uploadMode 自适应。
    private var pollInterval: TimeInterval {
        switch config.uploadMode {
        case .always:
            return 1.0
        case .batchThreshold:
            return 5.0
        case .interval:
            return min(config.uploadInterval, 5.0)
        case .intelligent:
            return isForeground ? 2.0 : 5.0
        }
    }

    /// 决定是否应在本次轮询中尝试上报。
    private var shouldDispatchThisCycle: Bool {
        switch config.uploadMode {
        case .always:
            return true          // 每次轮询都尝试
        case .batchThreshold:
            return true          // 有数据就尝试（Pipeline 控制阈值）
        case .interval:
            return true          // 轮询即上报
        case .intelligent:
            return true          // 交给 dispatchIfNeeded 内部判断
        }
    }

    // ────────────────────────────────────────────
    //  MARK: - Dispatch logic
    // ────────────────────────────────────────────

    @discardableResult
    private func dispatchIfNeeded() async -> Bool {
        guard !isUploading else { return false }
        isUploading = true
        defer { isUploading = false }

        let batches: [Data]
        do {
            batches = try await storage.popAll(forKey: "events_wal")
        } catch {
            consecutiveFailures = 0
            return false
        }
        guard !batches.isEmpty else {
            consecutiveFailures = 0
            return false
        }

        var anySent = false
        for rawData in batches {
            guard !rawData.isEmpty else { continue }

            let batch: StatisticsBatch
            do {
                batch = try StatisticsBatch.from(binaryData: rawData)
            } catch {
                log("[KFStatistics] corrupt batch: \(error)", level: .warning)
                continue
            }

            for attempt in 0..<max(1, config.maxRetries) {
                do {
                    let accepted = try await transport.send(batch: batch)
                    consecutiveFailures = 0
                    log("[KFStatistics] sent \(accepted) event(s)", level: .info)
                    anySent = true
                    break

                } catch StatisticsTransportError.invalidResponse(let code) where code == 429 {
                    let delay = backoffDelay(for: attempt)
                    log("[KFStatistics] rate-limited, retry in \(delay)s", level: .warning)
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

                } catch {
                    consecutiveFailures += 1
                    let delay = backoffDelay(for: attempt)
                    log("[KFStatistics] send failed (\(error)), retry in \(delay)s", level: .error)
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }

        return anySent
    }

    // ────────────────────────────────────────────
    //  MARK: - Backoff
    // ────────────────────────────────────────────

    private func backoffDelay(for attempt: Int) -> TimeInterval {
        let exponential = config.backoffBaseSeconds * pow(2.0, Double(attempt))
        let capped = min(exponential, 60.0)
        let jitter = Double.random(in: -capped * 0.25...capped * 0.25)
        return max(capped + jitter, 0.5)
    }

    // ────────────────────────────────────────────
    //  MARK: - Logging
    // ────────────────────────────────────────────

    private func log(_ message: String, level: StatisticsLogLevel = .debug) {
        guard config.logLevel != .off,
              level.rawValue >= config.logLevel.rawValue
        else { return }
        #if DEBUG
        print(message)
        #else
        if config.consoleLogEnabled { print(message) }
        #endif
    }
}

extension StatisticsLogLevel: Comparable {
    private var sortOrder: Int {
        switch self {
        case .debug:   return 0
        case .info:    return 1
        case .warning: return 2
        case .error:   return 3
        case .off:     return 4
        }
    }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}
