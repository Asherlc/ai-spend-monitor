import XCTest

@testable import AISpendCore

final class MoneyTests: XCTestCase {
  func testAdditionRejectsMixedCurrencies() throws {
    if ProcessInfo.processInfo.environment["AI_SPEND_TEST_MIXED_ADDITION"] == "1" {
      _ = Money(1) + Money(1, currency: "EUR")
      return
    }

    try assertProcessRejectsMixedCurrencyArithmetic(
      testName: #function,
      environmentKey: "AI_SPEND_TEST_MIXED_ADDITION"
    )
  }

  func testSubtractionRejectsMixedCurrencies() throws {
    if ProcessInfo.processInfo.environment["AI_SPEND_TEST_MIXED_SUBTRACTION"] == "1" {
      _ = Money(1) - Money(1, currency: "EUR")
      return
    }

    try assertProcessRejectsMixedCurrencyArithmetic(
      testName: #function,
      environmentKey: "AI_SPEND_TEST_MIXED_SUBTRACTION"
    )
  }

  func testDecimalAdditionDoesNotUseBinaryFloatingPoint() {
    XCTAssertEqual(
      Money(Decimal(string: "0.10")!) + Money(Decimal(string: "0.20")!),
      Money(Decimal(string: "0.30")!)
    )
  }

  func testRejectsNonUSDAtDecodeBoundary() throws {
    let data = #"{"amount":"1.25","currency":"EUR"}"#.data(using: .utf8)!
    XCTAssertThrowsError(try JSONDecoder().decode(Money.self, from: data))
  }

  private func assertProcessRejectsMixedCurrencyArithmetic(
    testName: String,
    environmentKey: String
  ) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = [
      "xctest",
      "-XCTest",
      "AISpendCoreTests.MoneyTests/\(testName)",
      Bundle(for: MoneyTests.self).bundleURL.path,
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    var environment = ProcessInfo.processInfo.environment
    environment[environmentKey] = "1"
    process.environment = environment

    try process.run()
    process.waitUntilExit()

    XCTAssertNotEqual(process.terminationStatus, 0)
  }
}
