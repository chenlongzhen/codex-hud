// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "CodexHUD",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "CodexHUD", targets: ["CodexHUD"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "HUDCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "CodexHUD", dependencies: ["HUDCore"]),
        .executableTarget(name: "HUDCoreChecks", dependencies: ["HUDCore"], path: "Tests/HUDCoreTests")
    ],
    swiftLanguageModes: [.v5]
)
