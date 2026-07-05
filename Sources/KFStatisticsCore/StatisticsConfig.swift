// ──────────────────────────────────────────────
//  StatisticsConfig — SDK Configuration
//
//  参考友盟+、神策数据、GrowingIO 等大厂 SDK
//  的配置体系设计，覆盖主流埋点框架的所有
//  可配置维度。
// ──────────────────────────────────────────────

import Foundation

// ═══════════════════════════════════════════════
//  MARK: - @StatisticsConfigurable property wrapper
// ═══════════════════════════════════════════════

@propertyWrapper
public struct StatisticsConfigurable<Value: Sendable>: Sendable {
    private let defaultValue: Value
    private var override: Value?

    public var wrappedValue: Value {
        get { override ?? defaultValue }
        set { override = newValue }
    }

    public init(default: Value) {
        self.defaultValue = `default`
    }
}

// ═══════════════════════════════════════════════
//  MARK: - Upload Mode
// ═══════════════════════════════════════════════

/// 事件上报策略，参考主流 SDK 的最佳实践。
public enum StatisticsUploadMode: String, Sendable, Codable, CaseIterable {
    /// **每次上报** — 每条事件产生后立即尝试上报。
    /// 适用于实时性要求高的场景（如支付事件）。
    /// 内部仍会先写入 WAL 再触发 dispatch。
    case always

    /// **阈值上报** — 事件数量达到 `uploadThreshold` 时上报。
    /// 主流 SDK 的默认策略，平衡实时性和网络开销。
    case batchThreshold

    /// **间隔上报** — 每 `uploadInterval` 秒上报一次。
    /// 适合低频场景，减少网络请求次数。
    case interval

    /// **智能模式** — 结合阈值+间隔+前后台切换：
    ///   - 前台：阈值或间隔触发（先到者）
    ///   - 后台：立即 flush
    ///   - 回前台：立即上报残留数据
    /// 推荐大多数场景使用。
    case intelligent
}

// ═══════════════════════════════════════════════
//  MARK: - Network Policy
// ═══════════════════════════════════════════════

/// 网络策略。
public enum StatisticsNetworkPolicy: String, Sendable, Codable, CaseIterable {
    /// 仅 WiFi 上报（省流量）
    case wifiOnly
    /// WiFi + 蜂窝均可
    case all
    /// 仅在非漫游时上报
    case nonRoaming
}

// ═══════════════════════════════════════════════
//  MARK: - Log Level
// ═══════════════════════════════════════════════

public enum StatisticsLogLevel: String, Sendable, Codable, CaseIterable {
    case debug
    case info
    case warning
    case error
    case off
}

// ═══════════════════════════════════════════════
//  MARK: - StatisticsConfig
// ═══════════════════════════════════════════════

/// KFStatistics 全局配置。
///
/// ```swift
/// KFStatistics.configure {
///     config.appKey = "your_app_key"
///     config.endpoint = URL(string: "https://api.kernelflux.com/events")!
///     config.uploadMode = .intelligent
///     config.uploadThreshold = 30
///     config.enableAutoPageTracking = true
/// }
/// ```
public struct StatisticsConfig: Sendable {

    // ╔══════════════════════════════════════════╗
    // ║  1. 基础配置 (Basic)                      ║
    // ╚══════════════════════════════════════════╝

    /// App 唯一标识，从 kernelflux.com 后台获取。
    /// 对应友盟的 AppKey / 神策的 ProjectID。
    @StatisticsConfigurable(default: "")
    public var appKey: String

    /// 分发渠道标记，如 "AppStore"、"TestFlight"、"Enterprise"。
    @StatisticsConfigurable(default: "AppStore")
    public var channel: String

    /// 上报服务器地址（便捷方式）。
    /// 设置后自动构造默认的 StatisticsHTTPTransport。
    /// 如需完全自定义传输层，请使用 `transport` 属性。
    @StatisticsConfigurable(default: nil)
    public var endpoint: URL?

    /// 完全自定义的上报实现。
    /// 设置此属性后 `endpoint` 不再生效。
    ///
    /// ```swift
    /// KFStatistics.configure {
    ///     config.transport = MyGRPCTransport()
    /// }
    /// ```
    @StatisticsConfigurable(default: nil)
    public var transport: (any StatisticsTransport)?

    /// 上报回调（推荐使用，适用于 90% 场景）。
    /// SDK 达到上报条件时调用此闭包，宿主方在闭包内发送网络请求。
    ///
    /// ```swift
    /// KFStatistics.configure { config in
    ///     config.uploadHandler = { batch in
    ///         let data = try JSONEncoder().encode(batch)
    ///         var req = URLRequest(url: URL(string: "https://api.xxx.com/events")!)
    ///         req.httpMethod = "POST"
    ///         req.httpBody = data
    ///         let (_, resp) = try await URLSession.shared.data(for: req)
    ///         return batch.events.count
    ///     }
    /// }
    /// ```
    /// 如果同时设置了 `transport`，`transport` 优先级更高。
    @StatisticsConfigurable(default: nil)
    public var uploadHandler: StatisticsUploadHandler?

    /// HTTP 传输层详细配置（仅在未自定义 transport 和 uploadHandler 时生效）。
    /// 设置此项后 `endpoint` 仅作为 baseURL。
    ///
    /// ```swift
    /// KFStatistics.configure {
    ///     config.httpConfig.method = "PUT"
    ///     config.httpConfig.headers["Authorization"] = "Bearer xxx"
    ///     config.httpConfig.encoding = .custom(ProtoEncoder())
    /// }
    /// ```
    @StatisticsConfigurable(default: nil)
    public var httpConfig: StatisticsHTTPTransportConfig?

    /// App 版本（自动获取，可不设置）
    @StatisticsConfigurable(default: "")
    public var appVersion: String

    /// 用户标识（哈希后），登录后可设置。
    @StatisticsConfigurable(default: "")
    public var userID: String

    /// 当前会话 ID，SDK 自动管理。
    @StatisticsConfigurable(default: "")
    public var sessionID: String

    // ╔══════════════════════════════════════════╗
    // ║  2. 上报策略 (Upload Strategy)            ║
    // ╚══════════════════════════════════════════╝

    /// 上报模式。默认 `.intelligent`（智能模式）。
    @StatisticsConfigurable(default: .intelligent)
    public var uploadMode: StatisticsUploadMode

    /// 事件条数阈值 — 缓存达到此数量时触发上报。
    /// 配合 `.batchThreshold` / `.intelligent` 模式使用。
    /// 参考：友盟默认 30 条，神策默认 100 条。
    @StatisticsConfigurable(default: 30)
    public var uploadThreshold: Int

    /// 上报间隔（秒）— 达到此时间触发上报。
    /// 配合 `.interval` / `.intelligent` 模式使用。
    /// 参考：友盟默认 15s，神策默认 10s。
    @StatisticsConfigurable(default: 10.0)
    public var uploadInterval: TimeInterval

    /// 单次上报最大事件数。超过此数量会被拆分。
    /// 参考：神策默认 500 条。
    @StatisticsConfigurable(default: 500)
    public var maxBatchSize: Int

    /// HTTP 重试次数。
    @StatisticsConfigurable(default: 3)
    public var maxRetries: Int

    /// 退避基准秒数（指数退避：1s → 2s → 4s …）
    @StatisticsConfigurable(default: 1.0)
    public var backoffBaseSeconds: TimeInterval

    /// HTTP 方法（便捷设置，等效于 httpConfig.method）。
    /// 仅当未自定义 transport 时生效。
    @StatisticsConfigurable(default: nil)
    public var httpMethod: String?

    /// 自定义请求头（便捷设置，等效于 httpConfig.headers[key]=value）。
    /// 仅当未自定义 transport 时生效。
    @StatisticsConfigurable(default: nil)
    public var httpHeaders: [String: String]?

    // ╔══════════════════════════════════════════╗
    // ║  3. 自动采集 (Auto Tracking)              ║
    // ╚══════════════════════════════════════════╝

    /// 自动页面埋点（Swizzle UIViewController）。
    /// 默认 true，参考友盟/神策默认行为。
    @StatisticsConfigurable(default: true)
    public var enableAutoPageTracking: Bool

    /// 自动点击埋点（预留）。
    @StatisticsConfigurable(default: false)
    public var enableAutoClickTracking: Bool

    /// 自动崩溃采集（预留）。
    @StatisticsConfigurable(default: true)
    public var enableCrashTracking: Bool

    /// 排除自动采集的 VC 类名列表。
    /// 例如：["_UIAlertControllerTextFieldViewController"]
    @StatisticsConfigurable(default: [])
    public var autoTrackingExcludedClasses: [String]

    // ╔══════════════════════════════════════════╗
    // ║  4. 存储策略 (Storage)                    ║
    // ╚══════════════════════════════════════════╝

    /// 最大缓存字节数。超过时丢弃最旧事件。
    /// 默认 5 MB。
    @StatisticsConfigurable(default: 5_242_880)
    public var maxStorageBytes: UInt64

    /// 存储加密开关（预留，需接入加密模块）。
    @StatisticsConfigurable(default: false)
    public var storageEncryptionEnabled: Bool

    // ╔══════════════════════════════════════════╗
    // ║  5. 网络策略 (Network)                    ║
    // ╚══════════════════════════════════════════╝

    /// 网络策略。默认 `.all`。
    @StatisticsConfigurable(default: .all)
    public var networkPolicy: StatisticsNetworkPolicy

    /// 启用数据压缩（zlib）。默认 true。
    @StatisticsConfigurable(default: true)
    public var enableCompression: Bool

    /// 压缩阈值（字节）。超过此大小的 batch 才压缩。
    @StatisticsConfigurable(default: 10_240)
    public var compressionThreshold: Int

    /// 请求超时时间（秒）。
    @StatisticsConfigurable(default: 15.0)
    public var requestTimeout: TimeInterval

    // ╔══════════════════════════════════════════╗
    // ║  6. 会话管理 (Session)                    ║
    // ╚══════════════════════════════════════════╝

    /// 会话超时时间（秒）。
    /// App 进入后台超过此时间后回到前台 → 新会话。
    /// 参考友盟默认 30 秒。
    @StatisticsConfigurable(default: 30.0)
    public var sessionTimeoutSeconds: TimeInterval

    // ╔══════════════════════════════════════════╗
    // ║  7. 调试与日志 (Debug)                    ║
    // ╚══════════════════════════════════════════╝

    /// 日志级别。Release 默认 `.off`。
    @StatisticsConfigurable(default: .off)
    public var logLevel: StatisticsLogLevel

    /// 是否允许 SDK 在 Debug 模式下输出日志到控制台。
    @StatisticsConfigurable(default: false)
    public var consoleLogEnabled: Bool

    // ╔══════════════════════════════════════════╗
    // ║  8. 隐私合规 (Privacy)                    ║
    // ╚══════════════════════════════════════════╝

    /// 用户选择退出采集。
    /// 设置 true 后 SDK 停止采集和上报。
    @StatisticsConfigurable(default: false)
    public var optOut: Bool

    /// 是否采集用户 ID (IDFV)。
    @StatisticsConfigurable(default: true)
    public var collectDeviceId: Bool

    // ╔══════════════════════════════════════════╗
    // ║  Init                                    ║
    // ╚══════════════════════════════════════════╝

    public init() {}

    /// 通过闭包批量修改配置。
    public mutating func apply(_ changes: (inout Self) -> Void) {
        changes(&self)
    }
}
