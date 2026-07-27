import AISpendCore
import Foundation
import SwiftData
import XCTest

@testable import AISpendBar

@MainActor
final class BudgetAlertRuntimeTests: XCTestCase {
  func testProductionCompositionDeliversAndPersistsMultipleBudgetAlerts() async throws {
    let repository = try makeRepository()
    let now = Date(timeIntervalSince1970: 1_721_062_800)
    let low = try repository.addBudget(limit: Money(500), now: now)
    let high = try repository.addBudget(
      limit: Money(1_500),
      now: now.addingTimeInterval(1)
    )
    for budget in [low, high] {
      try repository.saveAlertState(
        StoredBudgetAlertState(
          budgetID: budget.id,
          lastPacingState: .onPace
        )
      )
    }
    var delivered: [BudgetAlertDecision] = []
    let calendar = Self.utcCalendar
    let runtime = BudgetAlertRuntime(
      repository: repository,
      calendarProvider: { calendar },
      deliver: {
        delivered.append($0)
        return $0.nextState
      }
    )

    let result = await runtime.process(
      snapshot: offPaceSnapshot(now: now, budgets: [low, high])
    )

    XCTAssertFalse(result.summary.isPartial)
    XCTAssertEqual(Set(delivered.map(\.budgetID)), [low.id, high.id])
    XCTAssertEqual(Set(delivered.map(\.kind)), [.immediate])
    XCTAssertEqual(
      try repository.alertState(for: low.id).lastPacingState,
      .offPace
    )
    XCTAssertEqual(
      try repository.alertState(for: high.id).lastPacingState,
      .offPace
    )
    XCTAssertNotNil(try repository.alertState(for: low.id).lastImmediateAlertAt)
    XCTAssertNotNil(try repository.alertState(for: high.id).lastImmediateAlertAt)
  }

  func testDeliveryFailureDoesNotAdvanceThrottleAndMarksSnapshotPartial() async throws {
    let repository = try makeRepository()
    let now = Date(timeIntervalSince1970: 1_721_062_800)
    let budget = try repository.addBudget(limit: Money(500), now: now)
    let prior = StoredBudgetAlertState(
      budgetID: budget.id,
      lastPacingState: .onPace
    )
    try repository.saveAlertState(prior)
    let calendar = Self.utcCalendar
    let runtime = BudgetAlertRuntime(
      repository: repository,
      calendarProvider: { calendar },
      deliver: { _ in
        throw RuntimeTestError.deliveryRejected(
          "Authorization: Bearer secret-notification-token"
        )
      }
    )

    let result = await runtime.process(
      snapshot: offPaceSnapshot(now: now, budgets: [budget])
    )

    XCTAssertTrue(result.summary.isPartial)
    XCTAssertEqual(try repository.alertState(for: budget.id), prior)
    let diagnostics = result.attempts.values.flatMap { $0 }
    guard
      case .failed(let message)? = diagnostics.first(where: {
        $0.strategyID == "budget-alert"
      })?.outcome
    else {
      return XCTFail("Expected a budget-alert diagnostic")
    }
    XCTAssertFalse(message.contains("secret-notification-token"))
    XCTAssertTrue(message.contains("[REDACTED]"))
  }

  func testDailyReminderAndOnPaceResetWorkThroughPersistedRuntimeState() async throws {
    let repository = try makeRepository()
    let firstDay = Date(timeIntervalSince1970: 1_721_062_800)
    let budget = try repository.addBudget(limit: Money(500), now: firstDay)
    try repository.saveAlertState(
      StoredBudgetAlertState(
        budgetID: budget.id,
        lastPacingState: .collecting
      )
    )
    var delivered: [BudgetAlertDecision] = []
    let calendar = Self.utcCalendar
    let runtime = BudgetAlertRuntime(
      repository: repository,
      calendarProvider: { calendar },
      deliver: {
        delivered.append($0)
        return $0.nextState
      }
    )

    _ = await runtime.process(
      snapshot: snapshot(
        now: firstDay,
        spend: Money(1_000),
        budgets: [budget]
      )
    )
    let nextDay = firstDay.addingTimeInterval(24 * 60 * 60)
    _ = await runtime.process(
      snapshot: snapshot(
        now: nextDay,
        spend: Money(1_000),
        budgets: [budget]
      )
    )
    _ = await runtime.process(
      snapshot: snapshot(
        now: nextDay.addingTimeInterval(60),
        spend: Money(100),
        budgets: [budget]
      )
    )
    let resetState = try repository.alertState(for: budget.id)
    _ = await runtime.process(
      snapshot: snapshot(
        now: nextDay.addingTimeInterval(120),
        spend: Money(1_000),
        budgets: [budget]
      )
    )

    XCTAssertEqual(
      delivered.map(\.kind),
      [.immediate, .dailyReminder, .immediate]
    )
    XCTAssertEqual(resetState.lastPacingState, .onPace)
    XCTAssertNil(resetState.lastReminderAt)
  }

  func testConcurrentEvaluationDoesNotDeliverDuplicateDecision() async throws {
    let repository = try makeRepository()
    let now = Date(timeIntervalSince1970: 1_721_062_800)
    let budget = try repository.addBudget(limit: Money(500), now: now)
    try repository.saveAlertState(
      StoredBudgetAlertState(
        budgetID: budget.id,
        lastPacingState: .onPace
      )
    )
    let gate = DeliveryGate()
    let calendar = Self.utcCalendar
    let runtime = BudgetAlertRuntime(
      repository: repository,
      calendarProvider: { calendar },
      deliver: { decision in
        await gate.deliver(decision)
      }
    )
    let snapshot = snapshot(
      now: now,
      spend: Money(1_000),
      budgets: [budget]
    )

    let first = Task { await runtime.process(snapshot: snapshot) }
    await gate.waitUntilStarted()
    let completion = CompletionProbe()
    let second = Task {
      _ = await runtime.process(snapshot: snapshot)
      await completion.markCompleted()
    }
    for _ in 0..<10 {
      await Task.yield()
    }
    let deliveryCountWhileFirstIsPending = await gate.deliveryCount
    let secondCompletedWhileFirstIsPending = await completion.isCompleted
    await gate.release()
    _ = await first.value
    _ = await second.value
    let finalDeliveryCount = await gate.deliveryCount

    XCTAssertEqual(deliveryCountWhileFirstIsPending, 1)
    XCTAssertFalse(secondCompletedWhileFirstIsPending)
    XCTAssertEqual(finalDeliveryCount, 1)
  }

  private func offPaceSnapshot(
    now: Date,
    budgets: [BudgetDefinition]
  ) -> RefreshSnapshot {
    snapshot(now: now, spend: Money(1_000), budgets: budgets)
  }

  private func snapshot(
    now: Date,
    spend: Money,
    budgets: [BudgetDefinition]
  ) -> RefreshSnapshot {
    let window = try! MonthWindow.current(
      containing: now,
      calendar: Self.utcCalendar
    )
    return RefreshSnapshot(
      summary: MonthlySummary(
        total: spend,
        actual: spend,
        estimated: .zero,
        providers: [],
        isPartial: false
      ),
      pacing: PacingEngine().evaluate(
        spend: spend,
        budgets: budgets,
        now: now,
        window: window,
        hasAnyData: true,
        allDataIsStale: false
      ),
      attempts: [:],
      allDataIsStale: false,
      refreshedAt: now,
      evaluatedAt: now,
      monthWindow: window,
      dataAvailability: .available
    )
  }

  private func makeRepository() throws -> SwiftDataLedgerRepository {
    let schema = Schema([
      SpendRecordEntity.self,
      ProviderStateEntity.self,
      BudgetEntity.self,
      BudgetAlertStateEntity.self,
    ])
    let configuration = ModelConfiguration(
      schema: schema,
      isStoredInMemoryOnly: true
    )
    let container = try ModelContainer(
      for: schema,
      configurations: [configuration]
    )
    return SwiftDataLedgerRepository(modelContainer: container)
  }

  private static var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }
}

private enum RuntimeTestError: Error {
  case deliveryRejected(String)
}

private actor DeliveryGate {
  private(set) var deliveryCount = 0
  private var isStarted = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  func deliver(
    _ decision: BudgetAlertDecision
  ) async -> StoredBudgetAlertState {
    deliveryCount += 1
    isStarted = true
    let waiters = startWaiters
    startWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    await withCheckedContinuation {
      releaseContinuation = $0
    }
    return decision.nextState
  }

  func waitUntilStarted() async {
    if isStarted { return }
    await withCheckedContinuation {
      startWaiters.append($0)
    }
  }

  func release() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}

private actor CompletionProbe {
  private(set) var isCompleted = false

  func markCompleted() {
    isCompleted = true
  }
}
