import XCTest

@testable import AISpendCore

final class PacingEngineTests: XCTestCase {
  func testProjectsWhenBudgetWillBeReachedBeforeMonthEnd() throws {
    let start = Date(timeIntervalSince1970: 0)
    let result = PacingEngine().evaluate(
      spend: Money(400),
      budgets: [
        BudgetDefinition(
          id: UUID(),
          limit: Money(500),
          isEnabled: true,
          createdAt: start
        )
      ],
      now: start.addingTimeInterval(180_000),
      window: MonthWindow(
        start: start,
        end: start.addingTimeInterval(360_000)
      ),
      hasAnyData: true,
      allDataIsStale: false
    )

    XCTAssertEqual(
      result.budgets.first?.exhaustionForecast,
      .projected(start.addingTimeInterval(225_000))
    )
    XCTAssertEqual(result.budgets.first?.usageFraction, 0.8)
  }

  func testTreatsExhaustionAtMonthEndAsLastingThroughMonth() {
    let start = Date(timeIntervalSince1970: 0)
    let result = PacingEngine().evaluate(
      spend: Money(400),
      budgets: [
        BudgetDefinition(
          id: UUID(),
          limit: Money(800),
          isEnabled: true,
          createdAt: start
        )
      ],
      now: start.addingTimeInterval(180_000),
      window: MonthWindow(
        start: start,
        end: start.addingTimeInterval(360_000)
      ),
      hasAnyData: true,
      allDataIsStale: false
    )

    XCTAssertEqual(
      result.budgets.first?.exhaustionForecast,
      .lastsThroughMonth
    )
  }

  func testReportsBudgetAlreadyReached() {
    let start = Date(timeIntervalSince1970: 0)
    let result = PacingEngine().evaluate(
      spend: Money(Decimal(string: "1125.90")!),
      budgets: [
        BudgetDefinition(
          id: UUID(),
          limit: Money(500),
          isEnabled: true,
          createdAt: start
        )
      ],
      now: start.addingTimeInterval(180_000),
      window: MonthWindow(
        start: start,
        end: start.addingTimeInterval(360_000)
      ),
      hasAnyData: true,
      allDataIsStale: false
    )

    XCTAssertEqual(result.budgets.first?.exhaustionForecast, .reached)
    XCTAssertEqual(result.budgets.first?.usageFraction, 1)
    XCTAssertEqual(
      result.budgets.first?.currentMargin,
      Money(Decimal(string: "-625.90")!)
    )
  }

  func testZeroSpendLastsThroughMonth() {
    let start = Date(timeIntervalSince1970: 0)
    let result = PacingEngine().evaluate(
      spend: .zero,
      budgets: [
        BudgetDefinition(
          id: UUID(),
          limit: Money(500),
          isEnabled: true,
          createdAt: start
        )
      ],
      now: start.addingTimeInterval(180_000),
      window: MonthWindow(
        start: start,
        end: start.addingTimeInterval(360_000)
      ),
      hasAnyData: true,
      allDataIsStale: false
    )

    XCTAssertEqual(
      result.budgets.first?.exhaustionForecast,
      .lastsThroughMonth
    )
  }

  func testOmitsExhaustionForecastWhileCollecting() {
    let start = Date(timeIntervalSince1970: 0)
    let result = PacingEngine().evaluate(
      spend: Money(5),
      budgets: [
        BudgetDefinition(
          id: UUID(),
          limit: Money(500),
          isEnabled: true,
          createdAt: start
        )
      ],
      now: start.addingTimeInterval(60),
      window: MonthWindow(
        start: start,
        end: start.addingTimeInterval(2_592_000)
      ),
      hasAnyData: true,
      allDataIsStale: false
    )

    XCTAssertNil(result.budgets.first?.exhaustionForecast)
  }

  func testOmitsExhaustionForecastWithoutData() {
    let start = Date(timeIntervalSince1970: 0)
    let result = PacingEngine().evaluate(
      spend: .zero,
      budgets: [
        BudgetDefinition(
          id: UUID(),
          limit: Money(500),
          isEnabled: true,
          createdAt: start
        )
      ],
      now: start.addingTimeInterval(86_400),
      window: MonthWindow(
        start: start,
        end: start.addingTimeInterval(2_592_000)
      ),
      hasAnyData: false,
      allDataIsStale: false
    )

    XCTAssertNil(result.budgets.first?.exhaustionForecast)
  }

  func testEvaluatesMultipleBudgetsIndependently() throws {
    let start = Date(timeIntervalSince1970: 0)
    let window = MonthWindow(start: start, end: start.addingTimeInterval(360_000))
    let result = PacingEngine().evaluate(
      spend: Money(400),
      budgets: [
        BudgetDefinition(id: UUID(), limit: Money(500), isEnabled: true, createdAt: start),
        BudgetDefinition(id: UUID(), limit: Money(1_500), isEnabled: true, createdAt: start),
      ],
      now: start.addingTimeInterval(180_000), window: window,
      hasAnyData: true, allDataIsStale: false)
    XCTAssertEqual(result.projection, Money(800))
    XCTAssertEqual(result.budgets.map(\.state), [.offPace, .onPace])
    XCTAssertEqual(
      result.budgets.map(\.exhaustionForecast),
      [
        .projected(start.addingTimeInterval(225_000)),
        .lastsThroughMonth,
      ]
    )
  }

  func testCollectsForFirstSixHours() {
    let start = Date(timeIntervalSince1970: 0)
    let window = MonthWindow(start: start, end: start.addingTimeInterval(2_592_000))
    let result = PacingEngine().evaluate(
      spend: Money(5), budgets: [], now: start.addingTimeInterval(60),
      window: window, hasAnyData: true, allDataIsStale: false)
    XCTAssertNil(result.projection)
    XCTAssertTrue(result.isCollecting)
  }

  func testCollectsForFirstSixHoursEvenWhenWindowIsShorter() {
    let start = Date(timeIntervalSince1970: 0)
    let result = PacingEngine().evaluate(
      spend: Money(5),
      budgets: [],
      now: start.addingTimeInterval(50),
      window: MonthWindow(start: start, end: start.addingTimeInterval(100)),
      hasAnyData: true,
      allDataIsStale: false
    )

    XCTAssertNil(result.projection)
    XCTAssertTrue(result.isCollecting)
  }

  func testReturnsUnknownBudgetStatesWithoutData() {
    let start = Date(timeIntervalSince1970: 0)
    let budget = BudgetDefinition(
      id: UUID(),
      limit: Money(500),
      isEnabled: true,
      createdAt: start
    )

    let result = PacingEngine().evaluate(
      spend: Money(0),
      budgets: [budget],
      now: start.addingTimeInterval(86_400),
      window: MonthWindow(start: start, end: start.addingTimeInterval(2_592_000)),
      hasAnyData: false,
      allDataIsStale: false
    )

    XCTAssertNil(result.projection)
    XCTAssertEqual(result.budgets.map(\.state), [.unknown])
  }

  func testIncludesOnlyEnabledBudgetsSortedByAscendingLimit() {
    let start = Date(timeIntervalSince1970: 0)
    let highID = UUID()
    let lowID = UUID()
    let disabledID = UUID()
    let result = PacingEngine().evaluate(
      spend: Money(100),
      budgets: [
        BudgetDefinition(
          id: highID,
          limit: Money(1_500),
          isEnabled: true,
          createdAt: start
        ),
        BudgetDefinition(
          id: disabledID,
          limit: Money(100),
          isEnabled: false,
          createdAt: start
        ),
        BudgetDefinition(
          id: lowID,
          limit: Money(500),
          isEnabled: true,
          createdAt: start
        ),
      ],
      now: start.addingTimeInterval(1_296_000),
      window: MonthWindow(start: start, end: start.addingTimeInterval(2_592_000)),
      hasAnyData: true,
      allDataIsStale: false
    )

    XCTAssertEqual(result.budgets.map(\.id), [lowID, highID])
  }

  func testMarksAllStaleProjectionPartial() {
    let start = Date(timeIntervalSince1970: 0)

    let result = PacingEngine().evaluate(
      spend: Money(100),
      budgets: [],
      now: start.addingTimeInterval(1_296_000),
      window: MonthWindow(start: start, end: start.addingTimeInterval(2_592_000)),
      hasAnyData: true,
      allDataIsStale: true
    )

    XCTAssertEqual(result.projection, Money(200))
    XCTAssertTrue(result.isPartial)
  }

  func testCalculatesProjectedMarginForEachBudget() {
    let start = Date(timeIntervalSince1970: 0)
    let result = PacingEngine().evaluate(
      spend: Money(100),
      budgets: [
        BudgetDefinition(
          id: UUID(),
          limit: Money(250),
          isEnabled: true,
          createdAt: start
        )
      ],
      now: start.addingTimeInterval(1_296_000),
      window: MonthWindow(start: start, end: start.addingTimeInterval(2_592_000)),
      hasAnyData: true,
      allDataIsStale: false
    )

    XCTAssertEqual(result.budgets.first?.projectedMargin, Money(50))
  }
}
