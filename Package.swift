// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "AgentPulse",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "AgentPulse", targets: ["AgentPulse"]),
        .executable(name: "AgentPulseCollectorSmoke", targets: ["AgentPulseCollectorSmoke"]),
        .library(name: "AgentPulseCore", targets: ["AgentPulseCore"]),
        .library(name: "AgentPulseR2", targets: ["AgentPulseR2"]),
        .library(name: "AgentPulseReporting", targets: ["AgentPulseReporting"]),
        .library(name: "AgentPulseUsage", targets: ["AgentPulseUsage"]),
    ],
    targets: [
        .target(
            name: "AgentPulseCore"
        ),
        .target(
            name: "AgentPulseR2"
        ),
        .target(
            name: "AgentPulseReporting"
        ),
        .target(
            name: "AgentPulseUsage",
            dependencies: ["AgentPulseCore", "AgentPulseReporting"]
        ),
        .executableTarget(
            name: "AgentPulse",
            dependencies: ["AgentPulseCore", "AgentPulseR2", "AgentPulseReporting", "AgentPulseUsage"]
        ),
        .executableTarget(
            name: "AgentPulseCollectorSmoke",
            dependencies: ["AgentPulseCore"]
        ),
        .testTarget(
            name: "AgentPulseCoreTests",
            dependencies: ["AgentPulseCore"],
            exclude: ["Fixtures", "VerificationMain.swift"]
        ),
        .executableTarget(
            name: "AgentPulseCoreVerification",
            dependencies: ["AgentPulseCore"],
            path: "Tests/AgentPulseCoreTests",
            exclude: [
                "CodexStatusCollectorTests.swift",
                "Fixtures",
                "ModelsAndTPSWindowTests.swift",
                "SQLiteSnapshotStoreTests.swift",
            ],
            sources: ["VerificationMain.swift"]
        ),
        .testTarget(
            name: "AgentPulseR2Tests",
            dependencies: ["AgentPulseR2"],
            exclude: ["VerificationMain.swift"]
        ),
        .executableTarget(
            name: "AgentPulseR2Verification",
            dependencies: ["AgentPulseR2"],
            path: "Tests/AgentPulseR2Tests",
            exclude: [
                "AWSSignatureV4Tests.swift",
                "ObjectKeyAndURLTests.swift",
                "R2ConfigurationTests.swift",
                "UploadStatusTests.swift",
            ],
            sources: ["VerificationMain.swift"]
        ),
        .testTarget(
            name: "AgentPulseReportingTests",
            dependencies: ["AgentPulseReporting"]
        ),
        .executableTarget(
            name: "AgentPulseReportingVerification",
            dependencies: ["AgentPulseReporting"]
        ),
        .executableTarget(
            name: "AgentPulseUsageVerification",
            dependencies: ["AgentPulseUsage"],
            path: "Tests/AgentPulseUsageVerification",
            sources: ["VerificationMain.swift"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
