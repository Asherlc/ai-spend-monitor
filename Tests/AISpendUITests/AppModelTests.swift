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

  func testNoDataSnapshotUsesUnavailableLabelsInsteadOfZeroDollars() {
    let noData = Self.snapshot(
      total: 0,
      providers: [],
      providerStates: [
        .openAI: StoredProviderState(provider: .openAI, isEnabled: true)
      ],
      dataAvailability: .unavailable
    )
    let model = AppModel(snapshot: noData, refresh: { _ in noData })

    XCTAssertEqual(model.availability, .unavailable)
    XCTAssertEqual(model.statusTitle, "No data")
    XCTAssertEqual(model.headlineTitle, "No current data")
    XCTAssertEqual(model.providerRows.first?.amountTitle, "No data")
  }

  func testSuccessfulEmptyProviderRendersMeasuredZero() {
    let knownZero = Self.snapshot(
      total: 0,
      providers: [],
      providerStates: [
        .openAI: StoredProviderState(
          provider: .openAI,
          isEnabled: true,
          lastSuccessfulAt: Date(timeIntervalSince1970: 100),
          refreshStatus: .success
        )
      ],
      dataAvailability: .available,
      providerAvailability: [.openAI: .available]
    )
    let model = AppModel(snapshot: knownZero, refresh: { _ in knownZero })

    XCTAssertEqual(model.availability, .available)
    XCTAssertEqual(model.statusTitle, "$0.00")
    XCTAssertEqual(model.headlineTitle, "$0.00")
    XCTAssertEqual(model.providerRows.first?.amountTitle, "$0.00")
  }

  func testProviderRowsIncludeEnabledProviderWithoutCachedSpend() {
    let failedClaude = StoredProviderState(
      provider: .claude,
      isEnabled: true,
      lastAttemptAt: Date(timeIntervalSince1970: 100),
      refreshStatus: .failed,
      lastFailureMessage: "Admin scope unavailable"
    )
    let snapshot = Self.snapshot(
      total: 12,
      providers: [
        ProviderSpendSummary(
          id: .cursor,
          actual: Money(12),
          estimated: .zero,
          models: []
        )
      ],
      providerStates: [
        .cursor: StoredProviderState(provider: .cursor, isEnabled: true),
        .claude: failedClaude,
      ],
      attempts: [
        .claude: [
          SourceAttempt(
            strategyID: "claude-actual",
            outcome: .failed(redactedMessage: "Admin scope unavailable")
          )
        ]
      ]
    )
    let model = AppModel(snapshot: snapshot, refresh: { _ in snapshot })

    XCTAssertEqual(model.providerRows.map(\.id), [.cursor, .claude])
    XCTAssertEqual(model.providerRows.last?.summary.total, .zero)
    XCTAssertEqual(model.providerRows.last?.attempts.count, 1)
  }

  func testProviderAmountDetailDoesNotRepeatAnAllEstimatedTotal() {
    let snapshot = Self.snapshot(
      total: 50,
      providers: [
        ProviderSpendSummary(
          id: .openAI,
          actual: .zero,
          estimated: Money(25),
          models: []
        ),
        ProviderSpendSummary(
          id: .claude,
          actual: Money(20),
          estimated: Money(5),
          models: []
        ),
      ]
    )
    let model = AppModel(snapshot: snapshot, refresh: { _ in snapshot })

    XCTAssertEqual(model.providerRows.first { $0.id == .openAI }?.amountDetail, "Estimated")
    XCTAssertEqual(model.providerRows.first { $0.id == .claude }?.amountDetail, "~$5.00 estimated")
  }

  func testMenuBarProgressUsesCurrentSpendAgainstLowestEnabledBudget() {
    let snapshot = Self.snapshot(
      total: 20,
      providers: [
        ProviderSpendSummary(
          id: .openAI,
          actual: Money(20),
          estimated: .zero,
          models: []
        )
      ],
      budgets: [
        BudgetDefinition(
          id: UUID(),
          limit: Money(25),
          isEnabled: false,
          createdAt: .distantPast
        ),
        BudgetDefinition(
          id: UUID(),
          limit: Money(100),
          isEnabled: true,
          createdAt: .distantPast
        ),
        BudgetDefinition(
          id: UUID(),
          limit: Money(50),
          isEnabled: true,
          createdAt: .distantPast
        ),
      ]
    )
    let model = AppModel(snapshot: snapshot, refresh: { _ in snapshot })

    guard let progress = model.menuBarBudgetProgress else {
      return XCTFail("Expected budget progress")
    }
    XCTAssertEqual(progress.limit, Money(50))
    XCTAssertEqual(progress.fraction, 0.4, accuracy: 0.0001)
    XCTAssertEqual(progress.percentage, 40)
    XCTAssertEqual(
      progress.accessibilityLabel,
      "40% of $50.00 budget used"
    )
  }

  func testMenuBarProgressClampsRenderedArcButRetainsOverspendPercentage() {
    let snapshot = Self.snapshot(
      total: 75,
      providers: [
        ProviderSpendSummary(
          id: .openAI,
          actual: Money(75),
          estimated: .zero,
          models: []
        )
      ],
      budgets: [
        BudgetDefinition(
          id: UUID(),
          limit: Money(50),
          isEnabled: true,
          createdAt: .distantPast
        )
      ]
    )
    let model = AppModel(snapshot: snapshot, refresh: { _ in snapshot })

    XCTAssertEqual(model.menuBarBudgetProgress?.fraction, 1)
    XCTAssertEqual(model.menuBarBudgetProgress?.percentage, 150)
    XCTAssertEqual(
      model.menuBarBudgetProgress?.accessibilityLabel,
      "150% of $50.00 budget used"
    )
  }

  func testMenuBarProgressAccessibilityRoundsFractionalPercentageToOneDecimal() {
    let snapshot = Self.snapshot(
      total: 20,
      providers: [
        ProviderSpendSummary(
          id: .openAI,
          actual: Money(20),
          estimated: .zero,
          models: []
        )
      ],
      budgets: [
        BudgetDefinition(
          id: UUID(),
          limit: Money(30),
          isEnabled: true,
          createdAt: .distantPast
        )
      ]
    )
    let model = AppModel(snapshot: snapshot, refresh: { _ in snapshot })

    XCTAssertEqual(
      model.menuBarBudgetProgress?.accessibilityLabel,
      "66.7% of $30.00 budget used"
    )
  }

  func testMenuBarAccessibilityCombinesSpendTitleAndBudgetProgress() {
    let snapshot = Self.snapshot(
      total: 20,
      providers: [
        ProviderSpendSummary(
          id: .openAI,
          actual: Money(20),
          estimated: .zero,
          models: []
        )
      ],
      budgets: [
        BudgetDefinition(
          id: UUID(),
          limit: Money(30),
          isEnabled: true,
          createdAt: .distantPast
        )
      ]
    )
    let model = AppModel(snapshot: snapshot, refresh: { _ in snapshot })

    XCTAssertEqual(
      model.menuBarAccessibilityLabel,
      "$20.00, 66.7% of $30.00 budget used"
    )
  }

  func testMenuBarProgressIsAbsentWithoutAnEnabledBudget() {
    let model = AppModel(
      snapshot: Self.initialSnapshot,
      refresh: { _ in Self.initialSnapshot }
    )

    XCTAssertNil(model.menuBarBudgetProgress)
  }

  func testMenuBarProgressIsAbsentWhenCurrentMonthDataIsUnavailable() {
    let snapshot = Self.snapshot(
      total: 20,
      providers: [],
      budgets: [
        BudgetDefinition(
          id: UUID(),
          limit: Money(50),
          isEnabled: true,
          createdAt: .distantPast
        )
      ],
      dataAvailability: .unavailable
    )
    let model = AppModel(snapshot: snapshot, refresh: { _ in snapshot })

    XCTAssertNil(model.menuBarBudgetProgress)
  }

  func testMenuBarProgressIsAbsentWhenAllDataIsStale() {
    let snapshot = Self.snapshot(
      total: 20,
      providers: [
        ProviderSpendSummary(
          id: .openAI,
          actual: Money(20),
          estimated: .zero,
          models: []
        )
      ],
      budgets: [
        BudgetDefinition(
          id: UUID(),
          limit: Money(50),
          isEnabled: true,
          createdAt: .distantPast
        )
      ],
      allDataIsStale: true
    )
    let model = AppModel(snapshot: snapshot, refresh: { _ in snapshot })

    XCTAssertNil(model.menuBarBudgetProgress)
  }

  func testMenuBarProgressRemainsAvailableForPartialCurrentData() {
    let snapshot = Self.snapshot(
      total: 20,
      providers: [
        ProviderSpendSummary(
          id: .openAI,
          actual: Money(20),
          estimated: .zero,
          models: []
        )
      ],
      budgets: [
        BudgetDefinition(
          id: UUID(),
          limit: Money(50),
          isEnabled: true,
          createdAt: .distantPast
        )
      ],
      isPartial: true
    )
    let model = AppModel(snapshot: snapshot, refresh: { _ in snapshot })

    guard let progress = model.menuBarBudgetProgress else {
      return XCTFail("Expected budget progress")
    }
    XCTAssertEqual(progress.fraction, 0.4, accuracy: 0.0001)
    XCTAssertTrue(model.needsAttention)
  }

  func testPreparingToAddBudgetSelectsBudgetSettings() {
    let model = AppModel(
      snapshot: Self.initialSnapshot,
      refresh: { _ in Self.initialSnapshot }
    )

    model.prepareToAddBudget()

    XCTAssertEqual(model.selectedSettingsTab, .budgets)
  }

  func testProviderStatusUsesProviderSpecificDatesAndCacheAge() {
    let lastSuccess = Date(timeIntervalSince1970: 50)
    let lastAttempt = Date(timeIntervalSince1970: 100)
    let snapshot = Self.snapshot(
      total: 12,
      providers: [],
      providerStates: [
        .claude: StoredProviderState(
          provider: .claude,
          isEnabled: true,
          lastAttemptAt: lastAttempt,
          lastSuccessfulAt: lastSuccess,
          refreshStatus: .failed,
          lastFailureMessage: "Temporary failure"
        )
      ],
      refreshedAt: lastAttempt,
      evaluatedAt: Date(timeIntervalSince1970: 150)
    )
    let model = AppModel(snapshot: snapshot, refresh: { _ in snapshot })

    let status = model.providerRows.first?.status
    XCTAssertEqual(status?.lastAttemptAt, lastAttempt)
    XCTAssertEqual(status?.lastSuccessfulAt, lastSuccess)
    XCTAssertEqual(
      status?.freshness,
      .cachedAfterFailure(age: 100, message: "Temporary failure")
    )
  }

  func testMonthTitleUsesAggregationWindowInsteadOfRefreshDate() {
    let january = MonthWindow(
      start: Date(timeIntervalSince1970: 0),
      end: Date(timeIntervalSince1970: 2_678_400)
    )
    let refreshedInFebruary = Date(timeIntervalSince1970: 3_000_000)
    let snapshot = Self.snapshot(
      total: 12,
      providers: [],
      monthWindow: january,
      refreshedAt: refreshedInFebruary
    )
    let model = AppModel(snapshot: snapshot, refresh: { _ in snapshot })

    XCTAssertEqual(model.monthTitle, SpendFormatting.month(january.start))
    XCTAssertNotEqual(model.monthTitle, SpendFormatting.month(refreshedInFebruary))
  }

  func testRecordLoaderFailureClearsDailyHistoryAndMarksItUnavailable() async throws {
    let record = try spendRecord(
      id: "before",
      start: Date(timeIntervalSince1970: 1_728_000),
      amount: 10,
      quality: .actual,
      source: "billing"
    )
    let loader = RecordLoaderStub(records: [record])
    let model = AppModel(
      snapshot: Self.updatedSnapshot,
      refresh: { _ in Self.updatedSnapshot },
      records: loader.load
    )
    loader.shouldFail = true

    await model.refresh()

    XCTAssertTrue(model.dailyHistoryUnavailable)
    XCTAssertTrue(model.dailySpend(for: .claude).isEmpty)
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
    budgets: [BudgetDefinition] = [],
    providerStates: [ProviderID: StoredProviderState] = [:],
    attempts: [ProviderID: [SourceAttempt]] = [:],
    dataAvailability: CurrentMonthDataAvailability? = nil,
    providerAvailability: [ProviderID: CurrentMonthDataAvailability] = [:],
    monthWindow: MonthWindow? = nil,
    refreshedAt: Date = Date(timeIntervalSince1970: 100),
    evaluatedAt: Date? = nil,
    isPartial: Bool = false,
    allDataIsStale: Bool = false
  ) -> RefreshSnapshot {
    let actual = providers.reduce(Money.zero) { $0 + $1.actual }
    let estimated = providers.reduce(Money.zero) { $0 + $1.estimated }
    let start = Date(timeIntervalSince1970: 0)
    let end = start.addingTimeInterval(30 * 24 * 60 * 60)
    let now = start.addingTimeInterval(10 * 24 * 60 * 60)
    let window = monthWindow ?? MonthWindow(start: start, end: end)
    return RefreshSnapshot(
      summary: MonthlySummary(
        total: Money(total),
        actual: actual,
        estimated: estimated,
        providers: providers,
        isPartial: isPartial
      ),
      pacing: PacingEngine().evaluate(
        spend: Money(total),
        budgets: budgets,
        now: now,
        window: window,
        hasAnyData: !providers.isEmpty,
        allDataIsStale: allDataIsStale,
        isPartial: isPartial
      ),
      attempts: attempts,
      allDataIsStale: allDataIsStale,
      refreshedAt: refreshedAt,
      evaluatedAt: evaluatedAt,
      monthWindow: window,
      providerStates: providerStates,
      dataAvailability: dataAvailability,
      providerAvailability: providerAvailability
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

private enum RecordLoadFailure: Error {
  case failed
}

@MainActor
private final class RecordLoaderStub {
  var shouldFail = false
  private let records: [SpendRecord]

  init(records: [SpendRecord]) {
    self.records = records
  }

  func load() throws -> [SpendRecord] {
    if shouldFail { throw RecordLoadFailure.failed }
    return records
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
