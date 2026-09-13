// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexTokenmaxxing",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "CodexTokenmaxxing", targets: ["QuotaMenuApp"])],
    targets: [
        .target(name: "QuotaCore"),
        .target(name: "CodexConnection", dependencies: ["QuotaCore"]),
        .executableTarget(name: "QuotaMenuApp", dependencies: ["QuotaCore", "CodexConnection"]),
        .executableTarget(name: "QuotaChecks", dependencies: ["QuotaCore", "CodexConnection"], path: "Tests")
    ],
    swiftLanguageModes: [.v5]
)
