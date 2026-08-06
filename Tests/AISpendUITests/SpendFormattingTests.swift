import AISpendCore
import Foundation
import XCTest

@testable import AISpendUI

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

  func testBudgetForecastFormatsProjectedReachDate() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
    let date = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 8, day: 18))
    )

    XCTAssertEqual(
      SpendFormatting.budgetForecast(
        .projected(date),
        calendar: calendar,
        locale: Locale(identifier: "en_US")
      ),
      "Projected to reach Aug 18"
    )
  }

  func testBudgetForecastReportsWhenBudgetIsReached() {
    XCTAssertEqual(
      SpendFormatting.budgetForecast(.reached),
      "Budget reached"
    )
  }

  func testBudgetForecastReportsWhenBudgetLastsThroughMonth() {
    XCTAssertEqual(
      SpendFormatting.budgetForecast(.lastsThroughMonth),
      "Lasts through month"
    )
  }

  func testReachedBudgetMarginUsesCurrentOverage() {
    XCTAssertEqual(
      SpendFormatting.budgetMargin(
        currentMargin: Money(Decimal(string: "-625.90")!),
        forecast: .reached,
        projectedMargin: Money(Decimal(string: "-5687.46")!)
      ),
      "$625.90 over now"
    )
  }

  func testUnreachedBudgetMarginIdentifiesProjectedOverage() {
    XCTAssertEqual(
      SpendFormatting.budgetMargin(
        currentMargin: Money(Decimal(string: "374.10")!),
        forecast: .projected(Date(timeIntervalSince1970: 0)),
        projectedMargin: Money(Decimal(string: "-4687.46")!)
      ),
      "$4,687.46 projected over"
    )
  }
}
