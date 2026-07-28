import AISpendCore
import AISpendUI
import SwiftData
import XCTest

@testable import AISpendBar

@MainActor
final class AppLifecycleControllerTests: XCTestCase {
  func testProviderDefaultsBackfillOnlyMissingFireworksState() throws {
    let schema = Schema([
      SpendRecordEntity.self,
      ProviderStateEntity.self,
      BudgetEntity.self,
      BudgetAlertStateEntity.self,
    ])
    let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(
      for: schema,
      configurations: [configuration]
    )
    let repository = SwiftDataLedgerRepository(modelContainer: container)
    try repository.saveProviderState(
      StoredProviderState(provider: .claude, isEnabled: false)
    )

    try AppEnvironment.installProviderDefaultsIfNeeded(in: repository)

    let states = try repository.providerStates()
    XCTAssertFalse(try XCTUnwrap(states[.claude]).isEnabled)
    XCTAssertTrue(try XCTUnwrap(states[.fireworks]).isEnabled)
    XCTAssertEqual(Set(states.keys), Set(ProviderID.allCases))
  }

  func testStartLaunchesOnceAndSchedulesPeriodicRefreshWithoutDuplicateLoops() async throws {
    var reasons: [RefreshReason] = []
    let lifecycle = AppLifecycleController(
      interval: .seconds(900),
      refresh: { reasons.append($0) },
      sleep: { _ in try await ContinuousClock().sleep(for: .milliseconds(5)) }
    )

    lifecycle.start()
    lifecycle.start()

    try await waitUntil { reasons.count >= 2 }

    XCTAssertEqual(reasons[0], .launch)
    XCTAssertEqual(reasons[1], .periodic)
    lifecycle.stop()
  }

  func testStopCancelsFuturePeriodicRefreshes() async throws {
    var reasons: [RefreshReason] = []
    let lifecycle = AppLifecycleController(
      interval: .seconds(900),
      refresh: { reasons.append($0) },
      sleep: { _ in try await ContinuousClock().sleep(for: .milliseconds(5)) }
    )

    lifecycle.start()
    try await waitUntil { reasons.count >= 2 }
    lifecycle.stop()
    let countAfterStop = reasons.count
    try await ContinuousClock().sleep(for: .milliseconds(20))

    XCTAssertFalse(lifecycle.isRunning)
    XCTAssertEqual(reasons.count, countAfterStop)
  }

  func testStopCancelsAnActiveAppModelRefresh() async throws {
    var refreshStarted = false
    var refreshWasCancelled = false
    let snapshot = Self.snapshot()
    let model = AppModel(
      snapshot: snapshot,
      refresh: { _ in
        refreshStarted = true
        while !Task.isCancelled {
          await Task.yield()
        }
        refreshWasCancelled = true
        return snapshot
      }
    )
    let lifecycle = AppLifecycleController(model: model)

    lifecycle.start()
    try await waitUntil { refreshStarted }
    lifecycle.stop()
    try await waitUntil { refreshWasCancelled }

    XCTAssertFalse(lifecycle.isRunning)
    XCTAssertFalse(model.isRefreshing)
  }

  private func waitUntil(
    timeout: Duration = .seconds(1),
    condition: @escaping @MainActor () -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
      guard clock.now < deadline else {
        XCTFail("Timed out waiting for lifecycle event")
        return
      }
      try await clock.sleep(for: .milliseconds(1))
    }
  }

  private static func snapshot() -> RefreshSnapshot {
    let start = Date(timeIntervalSince1970: 0)
    let window = MonthWindow(
      start: start,
      end: start.addingTimeInterval(30 * 24 * 60 * 60)
    )
    return RefreshSnapshot(
      summary: MonthlySummary(
        total: .zero,
        actual: .zero,
        estimated: .zero,
        providers: [],
        isPartial: false
      ),
      pacing: PacingEngine().evaluate(
        spend: .zero,
        budgets: [],
        now: start.addingTimeInterval(24 * 60 * 60),
        window: window,
        hasAnyData: false,
        allDataIsStale: false
      ),
      attempts: [:],
      allDataIsStale: false,
      refreshedAt: start,
      monthWindow: window,
      dataAvailability: .unavailable
    )
  }
}
