// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "AISpendBar",
  platforms: [.macOS(.v14)],
  products: [.executable(name: "AISpendBar", targets: ["AISpendBar"])],
  targets: [
    .target(name: "AISpendCore"),
    .target(
      name: "AISpendProviders",
      dependencies: ["AISpendCore"],
      resources: [.process("Resources")],
      linkerSettings: [.linkedLibrary("sqlite3")]
    ),
    .target(name: "AISpendUI", dependencies: ["AISpendCore", "AISpendProviders"]),
    .executableTarget(
      name: "AISpendBar",
      dependencies: ["AISpendCore", "AISpendProviders", "AISpendUI"],
      resources: [.process("Resources")]
    ),
    .testTarget(name: "AISpendCoreTests", dependencies: ["AISpendCore"]),
  ],
  swiftLanguageModes: [.v6]
)
