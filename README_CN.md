# KFStatistics — Swift 原生埋点 SDK

[![Swift](https://img.shields.io/badge/Swift-6.0-FA7343?logo=swift)](https://swift.org)
[![Platform](https://img.shields.io/badge/iOS-16.0+-blue?logo=apple)](https://developer.apple.com/ios)
[![SPM](https://img.shields.io/badge/SPM-compatible-brightgreen)](https://swift.org/package-manager)

**KFStatistics**（KernelFlux Statistics）是纯 Swift 6 的事件埋点 SDK。基于 Actor 实现无锁并发，`@Trackable` 宏提供编译期类型安全的事件定义，Serializer → Storage → Transport 可插拔管线。

> [English](README.md)

---

## 快速开始

### 1. 添加依赖

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/kernelflux/kfstatistics.git", from: "1.0.5"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "KFStatistics", package: "kfstatistics"),
    ]),
]
```

### 2. 定义事件

```swift
import KFStatistics

@Trackable
struct Purchase {
    let itemID: String
    let price: Double
    let quantity: Int64
}
```

`@Trackable` 宏在编译期自动生成 `EventProtocol` 遵守、`Codable`、`Sendable` 以及二进制字段描述表。

### 3. 配置并启动

```swift
KFStatistics.configure { config in
    config.appKey   = "your_app_key"
    config.endpoint = URL(string: "https://api.yourdomain.com/events")!
    config.uploadMode = .intelligent
}
KFStatistics.start()
```

或通过 KFService DI：

```swift
import KFService
import KFStatistics

// App init
ServiceContainer.shared.install(KFStatisticsAssembly())

// App.task
try await Engine.run(modules: [
    KFStatisticsStartupModule(config: {
        var c = StatisticsConfig()
        c.appKey = "haircare"
        c.uploadMode = .intelligent
        c.uploadThreshold = 30
        return c
    }()),
])
```

### 4. 埋点

```swift
// 强类型（编译期安全，通过 @Trackable）
KFStatistics.track(Purchase(itemID: "sku_123", price: 29.99, quantity: 2))

// 动态（字符串事件名）
KFStatistics.track("Search", ["query": "swift", "results": 5])

// 原始字典（自动装箱为 StatisticsValue）
KFStatistics.track("Custom", ["key": "value", "count": 42])
```

---

## 架构

```
           App 层
              │
     ┌────────▼────────┐
     │   Serializer     │  结构体字段 → 二进制 payload
     │   (公开)          │
     └────────┬────────┘
              │ 二进制 payload
     ┌────────▼────────┐
     │   Pipeline       │  Batch → PropertyList 二进制
     │   (Actor)        │
     └────────┬────────┘
              │ 纯二进制 Data
     ┌────────▼────────┐
     │  Storage (mmap)  │  崩溃安全，append-only WAL
     │   (内部实现)      │
     └────────┬────────┘
              │ 二进制 Data
     ┌────────▼────────┐
     │  Dispatcher      │  popAll → uploadHandler
     │   (Actor)        │
     └────────┬────────┘
              │ StatisticsBatch
     ┌────────┴────────┐
     │                  │
┌────▼───────┐  ┌───────▼──────────┐
│ upload     │  │ Statistics       │
│ Handler    │  │ Transport         │
│ (简易方式)  │  │ (高级方式)        │
└────────────┘  └───────────────────┘
```

所有事件走统一链路：track → 序列化 → 持久化 → dispatch。`uploadHandler` / `StatisticsTransport` 收到 `StatisticsRecord`，包含 `eventName`、`payload`（protobuf 二进制，用于高效网络传输）和 `fields` 元数据（用于反序列化）。

### 可插拔层级

| 层级 | 协议 | 默认实现 | 外部可替换 |
|------|------|---------|:--------:|
| 传输 | `StatisticsTransport`（公开） | `StatisticsHTTPTransport` (URLSession) | ✅ |
| 存储 | `StatisticsStorage`（内部） | `StatisticsFileStorage` (mmap WAL) | ❌ |
| 序列化 | `StatisticsSerializer`（公开） | `StatisticsBinarySerializer` | ✅ |

---

## 设计理念

**Actor 并发替代锁。** Pipeline 和 Dispatcher 均为 Swift Actor，热路径无锁竞争。事件入队通过无锁 RingBuffer，所有 I/O（序列化、文件写入、网络）在主线程外完成。

**二进制序列化。** 每个 `@Trackable` 结构体在编译期生成字段描述表（`[FieldDescriptor]`），序列化器使用 protobuf 兼容的二进制格式——产物体积小，适合百万日活级别的网络传输。

**mmap 持久化。** 文件存储采用内存映射 I/O + 追加写 + WAL，崩溃安全：最多丢失 1 条事件。

**宏驱动类型安全。** `@Trackable` 消除字符串事件名和字典参数，编译期代码生成保证事件 Schema 与数据一致。

---

## 4 种上报模式

| 模式 | 行为 | 适用场景 |
|------|------|---------|
| `.always` | 每条事件立即上报 | 支付、关键转化 |
| `.batchThreshold` | 达到阈值上报 | 平衡模式（默认 30 条） |
| `.interval` | 间隔上报 | 低频场景 |
| `.intelligent` | 阈值+间隔+前后台切换 | **推荐** |

```swift
KFStatistics.configure { config in
    config.uploadMode = .intelligent
    config.uploadThreshold = 30
    config.uploadInterval  = 10
}
```

---

## 传输层

### 简易方式：`uploadHandler`（推荐）

```swift
KFStatistics.configure { config in
    config.uploadHandler = { batch in
        let data = try JSONEncoder().encode(batch)
        var req = URLRequest(url: URL(string: "https://api.xxx.com/events")!)
        req.httpMethod = "POST"
        req.httpBody = data
        let (_, resp) = try await URLSession.shared.data(for: req)
        return batch.events.count
    }
}
```

同时设置 `uploadHandler` 和 `transport` 时，`transport` 优先。

---

## 第三方 SDK 转发（友盟 / Firebase）

商业化 SDK 在 `uploadHandler` 中转发，走完持久化之后才调。通过 `record.deserialize()` 将二进制 payload 反序列化为键值字典：

```swift
// 友盟（中国区）
config.uploadHandler = { batch in
    for record in batch.events {
        var attrs = [String: String]()
        let props = (try? record.deserialize()) ?? [:]
        for (k, v) in props {
            if case .string(let s) = v { attrs[k] = s }
        }
        MobClick.event(record.eventName, attributes: attrs)
    }
    // ... 然后可选地 HTTP 上传到自研服务端
    return batch.events.count
}

// Firebase（国际区）
config.uploadHandler = { batch in
    for record in batch.events {
        var params: [String: Any] = [:]
        let props = (try? record.deserialize()) ?? [:]
        for (k, v) in props {
            switch v {
            case .string(let s): params[k] = s
            case .int64(let i):  params[k] = i
            case .uint64(let u): params[k] = u
            case .double(let d): params[k] = d
            case .bool(let b):   params[k] = b ? "true" : "false"
            case .data:          break
            }
        }
        Analytics.logEvent(record.eventName, parameters: params.isEmpty ? nil : params)
    }
    return batch.events.count
}
```

宿主 App 自行决定是否集成友盟/Firebase——kfstatistics 不依赖任何商业化 SDK。

---

## 配置项参考

| 分类 | 字段 | 默认值 | 说明 |
|------|------|--------|------|
| 基础 | `appKey` | `""` | App 标识 |
| | `endpoint` | `nil` | 上报地址 |
| 上传 | `uploadMode` | `.intelligent` | 上传策略 |
| | `uploadThreshold` | `30` | 阈值（条） |
| | `uploadInterval` | `10` | 间隔（秒） |
| | `maxRetries` | `3` | 重试次数 |
| 自动 | `enableAutoPageTracking` | `true` | UIKit 自动采集 |
| 网络 | `enableCompression` | `true` | zlib 压缩 |
| | `httpMethod` | `nil` | 快捷设置，如 `"PUT"` |
| | `httpHeaders` | `nil` | 自定义请求头 |
| 隐私 | `optOut` | `false` | 退出采集 |
| 调试 | `logLevel` | `.off` | 日志级别 |

---

## 页面自动采集

### UIKit（零侵入，Method Swizzling）

```swift
// "HomeViewController" → 页面名 "Home"
```

自定义页面名：

```swift
final class ProfileVC: UIViewController, StatisticsTrackablePage {
    var trackingPageName: String { "Profile" }
}
```

### SwiftUI（声明式）

```swift
struct HomeView: View {
    var body: some View {
        VStack { Text("Hello") }
            .trackPage("Home")
    }
}
```

---

## 产品

| Product | 说明 |
|---------|------|
| `KFStatistics` | 完整 SDK（Core + Macros + Runtime） |
| `KFStatisticsCore` | 纯协议层 — `EventProtocol`、`StatisticsConfig`、`StatisticsTransport`、`StatisticsBatch` |
| `KFStatisticsMacros` | `@Trackable` 宏实现 |

---

## 性能

| 操作 | 延迟 |
|------|------|
| 单事件入队 (RingBuffer) | < 1 µs |
| 批量序列化 (100 条) | ~1 ms |
| 文件写入 (1,000 条) | ~15 ms |
| 主线程阻塞 | **0**（全 Actor） |
| 崩溃丢事件 | ≤ 1 条（mmap WAL） |

---

## 系统要求

- iOS 16.0+ / macOS 13.0+ / tvOS 16.0+ / watchOS 9.0+ / visionOS 1.0+
- Swift 6.0+ (Xcode 16+)
- SPM

---

## 源码结构

```
Sources/
├── KFStatisticsCore/          ← 协议 + 类型（零依赖）
│   ├── EventProtocol.swift        EventProtocol, FieldDescriptor, StatisticsPriority
│   ├── StatisticsConfig.swift     StatisticsConfig, UploadMode, NetworkPolicy
│   ├── StatisticsBatch.swift      Batch 模型
│   ├── StatisticsTransport.swift  StatisticsTransport 协议, UploadHandler
│   └── StatisticsTrackablePage.swift
├── KFStatistics/              ← 运行时引擎
│   ├── Statistics.swift           公开入口（KFStatistics enum）
│   ├── StatisticsPipeline.swift   Actor 批处理 + 序列化
│   ├── Serialization/             二进制序列化器（1.0.5 起公开）
│   ├── Storage/                   mmap 文件存储
│   ├── Dispatch/                  Dispatcher Actor + 传输
│   ├── AutoTracking/              UIKit Swizzling + SwiftUI Modifier
│   └── Utility/                   RingBuffer, AnyEvent
├── KFStatisticsMacros/        ← @Trackable 宏实现
└── KFStatisticsTestSupport/   ← 测试 Mock Storage
```

---

## 业内对比

| 特性 | KFStatistics | Sentry | Firebase | 友盟+ | 神策 |
|------|:-----------:|:------:|:--------:|:-----:|:----:|
| 纯 Swift 6 | ✅ | ❌ | ❌ | ❌ | ❌ |
| Actor 并发 | ✅ | ❌ | ❌ | ❌ | ❌ |
| 宏类型安全 | ✅ | ❌ | ❌ | ❌ | ❌ |
| Transport 可换 | ✅ | ✅ | ❌ | ❌ | ❌ |
| 4 种上报模式 | ✅ | ❌ | ❌ | ❌ | ❌ |
| SwiftUI 采集 | ✅ | ✅ | ❌ | ❌ | ❌ |
| mmap 崩溃安全 | ✅ | ❌ | ❌ | ❌ | ❌ |

---

## License

[MIT](LICENSE) © KernelFlux
