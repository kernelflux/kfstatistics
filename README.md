# KFStatistics — Swift-Native Analytics SDK

[![Swift](https://img.shields.io/badge/Swift-6.0-FA7343?logo=swift)](https://swift.org)
[![Platform](https://img.shields.io/badge/iOS-16.0+-blue?logo=apple)](https://developer.apple.com/ios)
[![SPM](https://img.shields.io/badge/SPM-compatible-brightgreen)](https://swift.org/package-manager)

**KFStatistics** is a Swift 6-native event tracking SDK. Built with Actors for lock-free concurrency, `@Trackable` macros for compile-time type-safe events, and a pluggable pipeline (Serializer → Storage → Transport).

## Quick Start

### 1. Add dependency

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

### 2. Define events

```swift
import KFStatistics

@Trackable
struct Purchase {
    let itemID: String
    let price: Double
    let quantity: Int64
}
```

The `@Trackable` macro auto-generates `EventProtocol` conformance, `Codable`, `Sendable`, and a binary field schema at compile time.

### 3. Configure & start

```swift
KFStatistics.configure { config in
    config.appKey   = "your_app_key"
    config.endpoint = URL(string: "https://api.yourdomain.com/events")!
    config.uploadMode = .intelligent
}
KFStatistics.start()
```

Or via KFService DI:

```swift
import KFService
import KFStatistics

// In App init
ServiceContainer.shared.install(KFStatisticsAssembly())

// In App.task
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

### 4. Track events

```swift
// Compile-time type-safe (via @Trackable)
KFStatistics.track(Purchase(itemID: "sku_123", price: 29.99, quantity: 2))

// Dynamic (string event name)
KFStatistics.track("Search", ["query": "swift", "results": 5])

// Raw dictionary (auto-boxed to StatisticsValue)
KFStatistics.track("Custom", ["key": "value", "count": 42])
```

## Architecture

```
           App Layer
              │
     ┌────────▼────────┐
     │   Serializer     │  Struct fields → binary payload
     │   (public)       │
     └────────┬────────┘
              │ binary payload
     ┌────────▼────────┐
     │   Pipeline       │  Batch → PropertyList binary
     │   (Actor)        │
     └────────┬────────┘
              │ binary Data
     ┌────────▼────────┐
     │  Storage (mmap)  │  Crash-safe, append-only WAL
     │   (internal)     │
     └────────┬────────┘
              │ binary Data
     ┌────────▼────────┐
     │  Dispatcher      │  popAll → decode → uploadHandler
     │   (Actor)        │
     └────────┬────────┘
              │ StatisticsBatch
     ┌────────┴────────┐
     │                 │
┌────▼───────┐  ┌──────▼──────────┐
│ upload     │  │ Statistics       │
│ Handler    │  │ Transport         │
│ (simple)   │  │ (advanced)        │
└────────────┘  └──────────────────┘
```

### Pluggable layers

| Layer | Protocol | Default | Replaceable |
|-------|----------|---------|:-----------:|
| Transport | `StatisticsTransport` (public) | `StatisticsHTTPTransport` (URLSession) | Yes |
| Storage | `StatisticsStorage` (internal) | `StatisticsFileStorage` (mmap WAL) | No |
| Serializer | `StatisticsSerializer` (public) | `StatisticsBinarySerializer` | Yes |

All events flow through the same pipeline: track → serialize → persist → dispatch. The `uploadHandler` / `StatisticsTransport` receives `StatisticsRecord` with `eventName`, `payload` (protobuf binary for efficient wire transfer), and `fields` metadata for deserialization.

## Upload Modes

| Mode | Behavior | Use Case |
|------|----------|----------|
| `.always` | Fire immediately per event | Payments, critical conversions |
| `.batchThreshold` | Fire when count ≥ threshold | Balanced (default 30 events) |
| `.interval` | Fire every N seconds | Low-frequency scenarios |
| `.intelligent` | Threshold + interval + foreground/background | **Recommended** |

## Transport

### Simple: `uploadHandler` (recommended)

```swift
var config = StatisticsConfig()
config.uploadHandler = { batch in
    let data = try JSONEncoder().encode(batch)
    var req = URLRequest(url: URL(string: "https://api.xxx.com/events")!)
    req.httpMethod = "POST"
    req.httpBody = data
    let (_, resp) = try await URLSession.shared.data(for: req)
    return batch.events.count
}
```

### Advanced: `StatisticsTransport` protocol

```swift
struct GRPCTransport: StatisticsTransport {
    func send(batch: StatisticsBatch) async throws -> Int {
        // Custom gRPC implementation
        return batch.events.count
    }
}
var config = StatisticsConfig()
config.transport = GRPCTransport()
```

## Third-party Forwarding (Umeng / Firebase)

Commercial SDKs are forwarded to **from within `uploadHandler`**, after persistence. Use `record.deserialize()` to decode the binary payload back to key-value properties:

```swift
// Umeng (China)
config.uploadHandler = { batch in
    for record in batch.events {
        var attrs = [String: String]()
        let props = (try? record.deserialize()) ?? [:]
        for (k, v) in props {
            if case .string(let s) = v { attrs[k] = s }
        }
        MobClick.event(record.eventName, attributes: attrs)
    }
    // ... then optionally HTTP upload to your own server
    return batch.events.count
}

// Firebase (Global)
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

The host app decides whether to integrate Umeng/Firebase — kfstatistics has no dependency on commercial SDKs.

## Products

| Product | Description |
|---------|-------------|
| `KFStatistics` | Full SDK (Core + Macros + Runtime) |
| `KFStatisticsCore` | Protocol-only layer — `EventProtocol`, `StatisticsConfig`, `StatisticsTransport`, `StatisticsBatch` |
| `KFStatisticsMacros` | `@Trackable` macro implementation |

## Performance

| Operation | Latency |
|-----------|---------|
| Single event enqueue (RingBuffer) | < 1 µs |
| Batch serialize (100 events) | ~1 ms |
| File write (1,000 events) | ~15 ms |
| Main thread blocking | **0** (all Actor) |
| Crash data loss | ≤ 1 event (mmap WAL) |

## Requirements

- iOS 16.0+ / macOS 13.0+ / tvOS 16.0+ / watchOS 9.0+ / visionOS 1.0+
- Swift 6.0+ (Xcode 16+)
- SPM

## Source Layout

```
Sources/
├── KFStatisticsCore/          ← Protocols + types (zero dependency)
│   ├── EventProtocol.swift        EventProtocol, FieldDescriptor, StatisticsPriority
│   ├── StatisticsConfig.swift     StatisticsConfig, UploadMode, NetworkPolicy
│   ├── StatisticsBatch.swift      Batch model
│   ├── StatisticsTransport.swift  StatisticsTransport protocol, UploadHandler
│   └── StatisticsTrackablePage.swift
├── KFStatistics/              ← Runtime engine + Assembly + StartupModule
│   ├── Statistics.swift           Public entry point (KFStatistics enum)
│   ├── StatisticsPipeline.swift   Actor-based batcher + serializer
│   ├── Serialization/             Binary serializer (public since 1.0.5)
│   ├── Storage/                   mmap-based file storage
│   ├── Dispatch/                  Dispatcher actor + transport
│   ├── AutoTracking/              UIKit swizzling + SwiftUI view modifier
│   └── Utility/                   RingBuffer, AnyEvent
├── KFStatisticsMacros/        ← @Trackable macro implementation
└── KFStatisticsTestSupport/   ← Mock storage for testing
```

## License

[MIT](LICENSE) © KernelFlux
