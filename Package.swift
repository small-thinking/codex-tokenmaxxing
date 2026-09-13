// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexTokenmaxxing",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "CodexTokenmaxxing", targets: ["QuotaMenuApp"])],
    targets: [
        .target(name: "QuotaCore"),
        .target(name: "TokenAccounting"),
        .target(name: "LoginItemSupport"),
        .target(name: "CodexConnection", dependencies: ["QuotaCore"]),
        .target(name: "QuotaMenuUI", dependencies: ["QuotaCore"]),
        .executableTarget(name: "QuotaMenuApp", dependencies: ["QuotaCore", "CodexConnection", "QuotaMenuUI", "LoginItemSupport", "TokenAccounting"]),
        .executableTarget(name: "QuotaChecks", dependencies: ["QuotaCore", "CodexConnection", "QuotaMenuUI", "LoginItemSupport", "TokenAccounting"], path: "Tests")
    ],
    swiftLanguageModes: [.v5]
)
