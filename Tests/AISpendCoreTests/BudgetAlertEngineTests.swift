import Foundation
import XCTest

@testable import AISpendCore

final class BudgetAlertEngineTests: XCTestCase {
  private let calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return calendar
  }()

  func testOnPaceToOffPaceCreatesImmediateDecision() {
    let budget = budget(limit: 500)
    let now = localDate(2026, 7, 15, 10)
    let result = evaluate(
      budgetEvaluations: [evaluation(budget, state: .offPace)],
      budgets: [budget],
      storedStates: [
        budget.id: StoredBudgetAlertState(
          budgetID: budget.id,
          lastPacingState: .onPace
        )
      ],
      now: now
    )

    XCTAssertEqual(result.decisions.map(\.kind), [.immediate])
    XCTAssertEqual(result.decisions.first?.nextState.lastPacingState, .offPace)
    XCTAssertEqual(result.decisions.first?.nextState.lastImmediateAlertAt, now)
    XCTAssertTrue(result.stateUpdates.isEmpty)
  }

  func testNilBaselineDoesNotNotifyAndDefersReminderUntilNextLocalDay() throws {
    let budget = budget(limit: 500)
    let baselineAt = localDate(2026, 7, 15, 10)
    let baseline = evaluate(
      budgetEvaluations: [evaluation(budget, state: .offPace)],
      budgets: [budget],
      storedStates: [:],
      now: baselineAt
    )

    XCTAssertTrue(baseline.decisions.isEmpty)
    let baselineState = try XCTUnwrap(baseline.stateUpdates.first)
    XCTAssertEqual(baselineState.lastPacingState, .offPace)

    let sameDay = evaluate(
      budgetEvaluations: [evaluation(budget, state: .offPace)],
      budgets: [budget],
      storedStates: [budget.id: baselineState],
      now: localDate(2026, 7, 15, 23)
    )
    let nextDay = evaluate(
      budgetEvaluations: [evaluation(budget, state: .offPace)],
      budgets: [budget],
      storedStates: [budget.id: baselineState],
      now: localDate(2026, 7, 16, 0, 1)
    )

    XCTAssertTrue(sameDay.decisions.isEmpty)
    XCTAssertEqual(nextDay.decisions.map(\.kind), [.dailyReminder])
  }

  func testUnknownBaselineDoesNotCreateImmediateDecision() throws {
    let budget = budget(limit: 500)
    let result = evaluate(
      budgetEvaluations: [evaluation(budget, state: .offPace)],
      budgets: [budget],
      storedStates: [
        budget.id: StoredBudgetAlertState(
          budgetID: budget.id,
          lastPacingState: .unknown
        )
      ],
      now: localDate(2026, 7, 15, 10)
    )

    XCTAssertTrue(result.decisions.isEmpty)
    XCTAssertEqual(
      try XCTUnwrap(result.stateUpdates.first).lastPacingState,
      .offPace
    )
  }

  func testSecondEvaluationOnImmediateAlertDayCreatesNoDecision() {
    let budget = budget(limit: 500)
    let immediateAt = localDate(2026, 7, 15, 9)
    let result = evaluate(
      budgetEvaluations: [evaluation(budget, state: .offPace)],
      budgets: [budget],
      storedStates: [
        budget.id: StoredBudgetAlertState(
          budgetID: budget.id,
          lastPacingState: .offPace,
          lastImmediateAlertAt: immediateAt
        )
      ],
      now: localDate(2026, 7, 15, 23)
    )

    XCTAssertTrue(result.decisions.isEmpty)
  }

  func testNextLocalDayWhileOffPaceCreatesDailyReminder() {
    let budget = budget(limit: 500)
    let now = localDate(2026, 7, 16, 0, 1)
    let result = evaluate(
      budgetEvaluations: [evaluation(budget, state: .offPace)],
      budgets: [budget],
      storedStates: [
        budget.id: StoredBudgetAlertState(
          budgetID: budget.id,
          lastPacingState: .offPace,
          lastImmediateAlertAt: localDate(2026, 7, 15, 23, 59)
        )
      ],
      now: now
    )

    XCTAssertEqual(result.decisions.map(\.kind), [.dailyReminder])
    XCTAssertEqual(result.decisions.first?.nextState.lastReminderAt, now)
  }

  func testReturningOnPaceResetsStateAndAllowsAnotherImmediateTransition() throws {
    let budget = budget(limit: 500)
    let priorAlert = localDate(2026, 7, 15, 10)
    let onPaceResult = evaluate(
      budgetEvaluations: [evaluation(budget, state: .onPace)],
      budgets: [budget],
      storedStates: [
        budget.id: StoredBudgetAlertState(
          budgetID: budget.id,
          lastPacingState: .offPace,
          lastImmediateAlertAt: priorAlert,
          lastReminderAt: localDate(2026, 7, 16, 10)
        )
      ],
      now: localDate(2026, 7, 16, 12)
    )

    XCTAssertTrue(onPaceResult.decisions.isEmpty)
    let resetState = try XCTUnwrap(onPaceResult.stateUpdates.first)
    XCTAssertEqual(resetState.lastPacingState, .onPace)
    XCTAssertNil(resetState.lastReminderAt)

    let offPaceResult = evaluate(
      budgetEvaluations: [evaluation(budget, state: .offPace)],
      budgets: [budget],
      storedStates: [budget.id: resetState],
      now: localDate(2026, 7, 16, 13)
    )

    XCTAssertEqual(offPaceResult.decisions.map(\.kind), [.immediate])
  }

  func testCollectingStateWithoutProjectionIsRecordedForNextTransition() throws {
    let budget = budget(limit: 500)
    let collecting = BudgetAlertEngine().evaluate(
      pacing: pacing(
        projection: nil,
        evaluations: [evaluation(budget, state: .collecting)]
      ),
      summary: summary(),
      budgets: [budget],
      storedStates: [
        budget.id: StoredBudgetAlertState(
          budgetID: budget.id,
          lastPacingState: .offPace,
          lastReminderAt: localDate(2026, 6, 30, 10)
        )
      ],
      now: localDate(2026, 7, 1, 2),
      calendar: calendar,
      allDataIsStale: false
    )

    let collectingState = try XCTUnwrap(collecting.stateUpdates.first)
    XCTAssertEqual(collectingState.lastPacingState, .collecting)

    let offPace = evaluate(
      budgetEvaluations: [evaluation(budget, state: .offPace)],
      budgets: [budget],
      storedStates: [budget.id: collectingState],
      now: localDate(2026, 7, 1, 7)
    )
    XCTAssertEqual(offPace.decisions.map(\.kind), [.immediate])
  }

  func testUnknownDisabledAndAllStaleBudgetsDoNotCreateAlertsOrStateUpdates() {
    let unknownBudget = budget(limit: 500)
    let disabledBudget = BudgetDefinition(
      id: UUID(),
      limit: Money(1_000),
      isEnabled: false,
      createdAt: .distantPast
    )
    let unknown = evaluate(
      budgetEvaluations: [evaluation(unknownBudget, state: .unknown)],
      budgets: [unknownBudget],
      storedStates: [:],
      now: localDate(2026, 7, 15, 10)
    )
    let disabled = evaluate(
      budgetEvaluations: [evaluation(disabledBudget, state: .offPace)],
      budgets: [disabledBudget],
      storedStates: [:],
      now: localDate(2026, 7, 15, 10)
    )
    let stale = evaluate(
      budgetEvaluations: [evaluation(unknownBudget, state: .offPace)],
      budgets: [unknownBudget],
      storedStates: [:],
      now: localDate(2026, 7, 15, 10),
      allDataIsStale: true
    )

    XCTAssertTrue(unknown.decisions.isEmpty)
    XCTAssertTrue(unknown.stateUpdates.isEmpty)
    XCTAssertTrue(disabled.decisions.isEmpty)
    XCTAssertTrue(disabled.stateUpdates.isEmpty)
    XCTAssertTrue(stale.decisions.isEmpty)
    XCTAssertTrue(stale.stateUpdates.isEmpty)
  }

  func testTwoOffPaceBudgetsCreateIndependentDecisions() {
    let low = budget(limit: 500)
    let high = budget(limit: 1_500)
    let result = evaluate(
      budgetEvaluations: [
        evaluation(low, state: .offPace),
        evaluation(high, state: .offPace),
      ],
      budgets: [high, low],
      storedStates: [
        low.id: StoredBudgetAlertState(
          budgetID: low.id,
          lastPacingState: .onPace
        ),
        high.id: StoredBudgetAlertState(
          budgetID: high.id,
          lastPacingState: .onPace
        ),
      ],
      now: localDate(2026, 7, 15, 10)
    )

    XCTAssertEqual(result.decisions.map(\.budgetID), [low.id, high.id])
    XCTAssertEqual(result.decisions.map(\.kind), [.immediate, .immediate])
  }

  func testDailyReminderUsesCalendarDayAcrossDSTBoundary() {
    let budget = budget(limit: 500)
    let prior = localDate(2026, 11, 1, 23, 30)
    let result = evaluate(
      budgetEvaluations: [evaluation(budget, state: .offPace)],
      budgets: [budget],
      storedStates: [
        budget.id: StoredBudgetAlertState(
          budgetID: budget.id,
          lastPacingState: .offPace,
          lastReminderAt: prior
        )
      ],
      now: localDate(2026, 11, 2, 0, 5)
    )

    XCTAssertEqual(result.decisions.map(\.kind), [.dailyReminder])
  }

  func testBodyContainsSpendProjectionBudgetAndDeterministicLargestProvider() {
    let budget = budget(limit: 500)
    let summary = MonthlySummary(
      total: Money(125.5),
      actual: Money(100),
      estimated: Money(25.5),
      providers: [
        ProviderSpendSummary(
          id: .cursor,
          actual: Money(100),
          estimated: .zero,
          models: []
        ),
        ProviderSpendSummary(
          id: .claude,
          actual: Money(100),
          estimated: .zero,
          models: []
        ),
      ],
      isPartial: false
    )
    let result = BudgetAlertEngine().evaluate(
      pacing: pacing(
        projection: Money(750.25),
        evaluations: [evaluation(budget, state: .offPace)]
      ),
      summary: summary,
      budgets: [budget],
      storedStates: [
        budget.id: StoredBudgetAlertState(
          budgetID: budget.id,
          lastPacingState: .onPace
        )
      ],
      now: localDate(2026, 7, 15, 10),
      calendar: calendar,
      allDataIsStale: false
    )

    let body = result.decisions.first?.body ?? ""
    XCTAssertTrue(body.contains("$125.50"))
    XCTAssertTrue(body.contains("$750.25"))
    XCTAssertTrue(body.contains("$500.00"))
    XCTAssertTrue(body.contains("Claude"))
    XCTAssertFalse(body.contains("Cursor"))
    XCTAssertEqual(result.decisions.first?.localDay, "2026-07-15")
  }

  func testDecisionsConvenienceReturnsOnlyNotificationDecisions() {
    let budget = budget(limit: 500)
    let decisions = BudgetAlertEngine().decisions(
      pacing: pacing(
        projection: Money(750),
        evaluations: [evaluation(budget, state: .offPace)]
      ),
      summary: summary(),
      budgets: [budget],
      storedStates: [
        budget.id: StoredBudgetAlertState(
          budgetID: budget.id,
          lastPacingState: .onPace
        )
      ],
      now: localDate(2026, 7, 15, 10),
      calendar: calendar,
      allDataIsStale: false
    )

    XCTAssertEqual(decisions.map(\.kind), [.immediate])
  }

  private func evaluate(
    budgetEvaluations: [BudgetEvaluation],
    budgets: [BudgetDefinition],
    storedStates: [UUID: StoredBudgetAlertState],
    now: Date,
    allDataIsStale: Bool = false
  ) -> BudgetAlertEvaluation {
    BudgetAlertEngine().evaluate(
      pacing: pacing(
        projection: Money(750),
        evaluations: budgetEvaluations
      ),
      summary: summary(),
      budgets: budgets,
      storedStates: storedStates,
      now: now,
      calendar: calendar,
      allDataIsStale: allDataIsStale
    )
  }

  private func budget(limit: Decimal) -> BudgetDefinition {
    BudgetDefinition(
      id: UUID(),
      limit: Money(limit),
      isEnabled: true,
      createdAt: .distantPast
    )
  }

  private func evaluation(
    _ budget: BudgetDefinition,
    state: BudgetPacingState
  ) -> BudgetEvaluation {
    BudgetEvaluation(
      id: budget.id,
      limit: budget.limit,
      state: state,
      projectedMargin: nil,
      exhaustionForecast: nil,
      usageFraction: nil
    )
  }

  private func pacing(
    projection: Money?,
    evaluations: [BudgetEvaluation]
  ) -> PacingResult {
    PacingResult(
      projection: projection,
      isCollecting: false,
      isPartial: false,
      budgets: evaluations
    )
  }

  private func summary() -> MonthlySummary {
    MonthlySummary(
      total: Money(125.5),
      actual: Money(100),
      estimated: Money(25.5),
      providers: [
        ProviderSpendSummary(
          id: .claude,
          actual: Money(80),
          estimated: Money(20),
          models: []
        )
      ],
      isPartial: false
    )
  }

  private func localDate(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    _ hour: Int,
    _ minute: Int = 0
  ) -> Date {
    calendar.date(
      from: DateComponents(
        year: year,
        month: month,
        day: day,
        hour: hour,
        minute: minute
      )
    )!
  }
}
