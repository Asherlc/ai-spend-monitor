import XCTest

@testable import AISpendCore

final class MoneyTests: XCTestCase {
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
}
