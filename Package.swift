// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "codex-usage-monitor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CodexUsageMonitor", targets: ["CodexUsageMonitor"]),
        .executable(name: "UsageInstanceProbe", targets: ["UsageInstanceProbe"])
    ],
    targets: [
        .target(name: "UsageCore"),
        .executableTarget(name: "CodexUsageMonitor", dependencies: ["UsageCore"]),
        .executableTarget(name: "UsageInstanceProbe", dependencies: ["UsageCore"], path: "Tests/InstanceProbe"),
        .testTarget(name: "UsageCoreTests", dependencies: ["UsageCore"]),
        .testTarget(name: "UsageUITests", dependencies: ["CodexUsageMonitor", "UsageCore"])
    ]
)
