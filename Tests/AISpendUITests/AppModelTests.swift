import AISpendCore
import AISpendUI
import Foundation
import XCTest

@MainActor
final class AppModelTests: XCTestCase {
  func testPopoverOpenedAsksCoordinatorForPopoverRefresh() async {
    let recorder = RefreshRecorder(snapshot: Self.updatedSnapshot)
    let model = AppModel(
      snapshot: Self.initialSnapshot,
      refresh: recorder.refresh
    )

    await model.popoverOpened()

    XCTAssertEqual(recorder.reasons, [.popover])
    XCTAssertEqual(model.snapshot.summary.total, Money(42))
  }

  func testRefreshKeepsLastSnapshotVisibleWhileLoading() async {
    let gate = RefreshGate(result: Self.updatedSnapshot)
    let model = AppModel(
      snapshot: Self.initialSnapshot,
      refresh: gate.refresh
    )

    let task = Task { await model.refresh() }
    await gate.waitUntilCalled()

    XCTAssertTrue(model.isRefreshing)
    XCTAssertEqual(model.snapshot.summary.total, Money(12))

    gate.resume()
    await task.value

    XCTAssertFalse(model.isRefreshing)
    XCTAssertEqual(model.snapshot.summary.total, Money(42))
  }

  func testSelectingProviderExposesMatchingSummary() {
    let model = AppModel(
      snapshot: Self.updatedSnapshot,
      refresh: { _ in Self.updatedSnapshot }
    )

    model.selectedProvider = .claude

    XCTAssertEqual(model.selectedProviderSummary?.id, .claude)
    XCTAssertEqual(model.selectedProviderSummary?.total, Money(30))
  }

  func testDerivedValuesSortBudgetsAndProvidersBySpend() {
    let model = AppModel(
      snapshot: Self.updatedSnapshot,
      refresh: { _ in Self.updatedSnapshot }
    )

    XCTAssertEqual(model.budgetEvaluations.map(\.limit), [Money(50), Money(100)])
    XCTAssertEqual(model.providerSummaries.map(\.id), [.claude, .openAI])
  }

  func testDailySpendGroupsByDayWithoutDoubleCountingSupersededEstimate() throws {
    let start = Date(timeIntervalSince1970: 1_728_000)
    let actual = try spendRecord(
      id: "actual",
      start: start,
      amount: 10,
      quality: .actual,
      source: "billing"
    )
    let overlappingEstimate = try spendRecord(
      id: "estimate",
      start: start,
      amount: 8,
      quality: .estimated,
      source: "logs"
    )
    let model = AppModel(
      snapshot: Self.updatedSnapshot,
      refresh: { _ in Self.updatedSnapshot },
      records: { [actual, overlappingEstimate] }
    )

    XCTAssertEqual(model.dailySpend(for: .claude).map(\.amount), [Money(10)])
  }

  private static let initialSnapshot = snapshot(
    total: 12,
    providers: [
      ProviderSpendSummary(
        id: .openAI,
        actual: Money(12),
        estimated: .zero,
        models: []
      )
    ]
  )

  private static let updatedSnapshot = snapshot(
    total: 42,
    providers: [
      ProviderSpendSummary(
        id: .openAI,
        actual: Money(12),
        estimated: .zero,
        models: []
      ),
      ProviderSpendSummary(
        id: .claude,
        actual: Money(25),
        estimated: Money(5),
        models: [
          ModelSpendSummary(model: "claude-sonnet", actual: Money(25), estimated: Money(5))
        ]
      ),
    ],
    budgets: [
      BudgetDefinition(id: UUID(), limit: Money(100), isEnabled: true, createdAt: .distantPast),
      BudgetDefinition(id: UUID(), limit: Money(50), isEnabled: true, createdAt: .distantPast),
    ]
  )

  private static func snapshot(
    total: Decimal,
    providers: [ProviderSpendSummary],
    budgets: [BudgetDefinition] = []
  ) -> RefreshSnapshot {
    let actual = providers.reduce(Money.zero) { $0 + $1.actual }
    let estimated = providers.reduce(Money.zero) { $0 + $1.estimated }
    let start = Date(timeIntervalSince1970: 0)
    let end = start.addingTimeInterval(30 * 24 * 60 * 60)
    let now = start.addingTimeInterval(10 * 24 * 60 * 60)
    return RefreshSnapshot(
      summary: MonthlySummary(
        total: Money(total),
        actual: actual,
        estimated: estimated,
        providers: providers,
        isPartial: false
      ),
      pacing: PacingEngine().evaluate(
        spend: Money(total),
        budgets: budgets,
        now: now,
        window: MonthWindow(start: start, end: end),
        hasAnyData: !providers.isEmpty,
        allDataIsStale: false
      ),
      attempts: [:],
      allDataIsStale: false,
      refreshedAt: Date(timeIntervalSince1970: 100)
    )
  }

  private func spendRecord(
    id: String,
    start: Date,
    amount: Decimal,
    quality: SpendQuality,
    source: String
  ) throws -> SpendRecord {
    try SpendRecord(
      id: id,
      provider: .claude,
      accountFingerprint: "account",
      model: "claude-sonnet",
      intervalStart: start,
      intervalEnd: start.addingTimeInterval(3_600),
      amount: Money(amount),
      quality: quality,
      sourceID: source,
      observationID: id,
      fetchedAt: start,
      estimate: nil
    )
  }
}

@MainActor
private final class RefreshRecorder {
  private(set) var reasons: [RefreshReason] = []
  private let snapshot: RefreshSnapshot

  init(snapshot: RefreshSnapshot) {
    self.snapshot = snapshot
  }

  func refresh(reason: RefreshReason) async -> RefreshSnapshot {
    reasons.append(reason)
    return snapshot
  }
}

@MainActor
private final class RefreshGate {
  private let result: RefreshSnapshot
  private var resultContinuation: CheckedContinuation<RefreshSnapshot, Never>?
  private var calledContinuation: CheckedContinuation<Void, Never>?
  private var wasCalled = false

  init(result: RefreshSnapshot) {
    self.result = result
  }

  func refresh(reason _: RefreshReason) async -> RefreshSnapshot {
    wasCalled = true
    calledContinuation?.resume()
    calledContinuation = nil
    return await withCheckedContinuation { resultContinuation = $0 }
  }

  func waitUntilCalled() async {
    if wasCalled { return }
    await withCheckedContinuation { calledContinuation = $0 }
  }

  func resume() {
    resultContinuation?.resume(returning: result)
    resultContinuation = nil
  }
}
