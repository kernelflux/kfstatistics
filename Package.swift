// swift-tools-version: 6.0

import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "KFStatistics",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .tvOS(.v16),
        .watchOS(.v9),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "KFStatistics", targets: ["KFStatistics"]),
        .library(name: "KFStatisticsCore", targets: ["KFStatisticsCore"]),
        .library(name: "KFStatisticsMacros", targets: ["KFStatisticsMacros"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.0"),
        .package(url: "https://github.com/kernelflux/kfservice.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "KFStatisticsCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "KFStatistics",
            dependencies: ["KFStatisticsCore", .product(name: "KFService", package: "KFService")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .macro(
            name: "KFStatisticsMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),

        .target(
            name: "KFStatisticsTestSupport",
            dependencies: ["KFStatistics"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "KFStatisticsMacroTests",
            dependencies: [
                "KFStatisticsMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "KFStatisticsTests",
            dependencies: ["KFStatistics", "KFStatisticsTestSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
