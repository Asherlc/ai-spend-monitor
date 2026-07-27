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
      linkerSettings: [
        .linkedFramework("Security"),
        .linkedLibrary("sqlite3"),
      ]
    ),
    .target(name: "AISpendUI", dependencies: ["AISpendCore", "AISpendProviders"]),
    .executableTarget(
      name: "AISpendBar",
      dependencies: ["AISpendCore", "AISpendProviders", "AISpendUI"],
      exclude: ["Resources/Info.plist"],
      resources: [.process("Resources")]
    ),
    .testTarget(name: "AISpendCoreTests", dependencies: ["AISpendCore"]),
    .testTarget(
      name: "AISpendProvidersTests",
      dependencies: ["AISpendCore", "AISpendProviders"],
      resources: [.copy("Fixtures")]
    ),
    .testTarget(
      name: "AISpendBarTests",
      dependencies: ["AISpendBar", "AISpendCore"]
    ),
    .testTarget(
      name: "AISpendUITests",
      dependencies: ["AISpendCore", "AISpendProviders", "AISpendUI"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
