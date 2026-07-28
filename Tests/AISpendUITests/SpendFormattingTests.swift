import AISpendCore
import AISpendUI
import Foundation
import XCTest

final class SpendFormattingTests: XCTestCase {
  func testMenuBarFormatsUSDWithTwoFractionDigits() {
    XCTAssertEqual(
      SpendFormatting.menuBar(Money(Decimal(string: "684.27")!)),
      "$684.27"
    )
  }

  func testEstimatedPrefixesApproximationMarker() {
    XCTAssertEqual(
      SpendFormatting.estimated(Money(Decimal(string: "63.20")!)),
      "~$63.20"
    )
  }

  func testShareFormatsAsACompactPercentage() {
    XCTAssertEqual(SpendFormatting.share(Decimal(string: "0.375")!), "37.5%")
  }
}
