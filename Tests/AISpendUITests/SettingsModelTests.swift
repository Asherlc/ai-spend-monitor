import AISpendCore
import AISpendUI
import Foundation
import XCTest

@MainActor
final class SettingsModelTests: XCTestCase {
  func testDisablingProviderPersistsBeforeRefreshAndReenableUsesProviderRefreshReason() async {
    let store = SettingsStoreSpy()
    let model = makeModel(store: store)

    await model.setProvider(.claude, enabled: false)
    await model.setProvider(.claude, enabled: true)

    XCTAssertEqual(
      store.events,
      [
        "save-provider:claude:false",
        "refresh:manual",
        "save-provider:claude:true",
        "refresh:providerEnabled:claude",
      ]
    )
  }

  func testProviderPersistenceFailureDoesNotRefreshOrLieAboutState() async {
    let store = SettingsStoreSpy()
    store.failProviderSave = true
    let model = makeModel(store: store)

    await model.setProvider(.claude, enabled: false)

    XCTAssertEqual(store.events, ["save-provider:claude:false"])
    XCTAssertTrue(model.providerSettings.first { $0.id == .claude }?.isEnabled == true)
    XCTAssertNotNil(model.settingsError)
  }

  func testAddsMultipleBudgetsSortedAscending() async {
    let store = SettingsStoreSpy()
    let model = makeModel(store: store)

    let highResult = await model.addBudget(decimalText: "1500")
    let lowResult = await model.addBudget(decimalText: "500")
    XCTAssertEqual(highResult, .success)
    XCTAssertEqual(lowResult, .success)

    XCTAssertEqual(model.budgets.map(\.limit), [Money(500), Money(1_500)])
  }

  func testRejectsDuplicateNonpositiveAndAmbiguousBudgetText() async {
    let store = SettingsStoreSpy()
    let model = makeModel(store: store)
    let initialResult = await model.addBudget(decimalText: "500")
    XCTAssertEqual(initialResult, .success)

    for text in ["500.00", "0", "-1", "1,500", "NaN", "inf"] {
      guard case .validationError = await model.addBudget(decimalText: text) else {
        return XCTFail("Expected validation error for \(text)")
      }
    }

    XCTAssertEqual(model.budgets.map(\.limit), [Money(500)])
  }

  func testUpdatingBudgetCanDisableItAndRemovalDeletesAlertState() async {
    let store = SettingsStoreSpy()
    let model = makeModel(store: store)
    let initialResult = await model.addBudget(decimalText: "500")
    XCTAssertEqual(initialResult, .success)
    let budget = try! XCTUnwrap(model.budgets.first)
    store.alertBudgetIDs.insert(budget.id)

    var disabled = budget
    disabled.isEnabled = false
    let updateResult = await model.updateBudget(disabled)
    XCTAssertEqual(updateResult, .success)
    await model.removeBudget(id: budget.id)

    XCTAssertTrue(model.budgets.isEmpty)
    XCTAssertFalse(store.alertBudgetIDs.contains(budget.id))
  }

  func testBrowserDiscoveryTogglePersistsWithoutChangingLocalDiscovery() async {
    let store = SettingsStoreSpy()
    let model = makeModel(store: store)

    await model.setBrowserDiscoveryEnabled(false)

    XCTAssertFalse(model.browserDiscoveryEnabled)
    XCTAssertFalse(store.browserDiscoveryEnabled)
    XCTAssertTrue(store.localDiscoveryEnabled)
  }

  func testFirstEnabledBudgetRequestsNotificationAuthorizationOnlyOnce() async {
    let store = SettingsStoreSpy()
    let model = makeModel(store: store)

    _ = await model.addBudget(decimalText: "500")
    _ = await model.addBudget(decimalText: "1500")

    XCTAssertEqual(store.notificationAuthorizationRequests, 1)
  }

  func testDiagnosticsExposeOnlySanitizedAttemptText() {
    let secret = "sk-secret-value"
    let snapshot = Self.makeSnapshot(
      attempts: [
        .claude: [
          SourceAttempt(
            strategyID: "claude-actual",
            outcome: .failed(
              redactedMessage: DiagnosticSanitizer().sanitize(
                "Authorization: Bearer \(secret)"
              )
            )
          )
        ]
      ]
    )
    let model = AppModel(snapshot: snapshot, refresh: { _ in snapshot })

    let text = model.diagnosticEntries(for: .claude).map(\.detail).joined()

    XCTAssertFalse(text.contains(secret))
    XCTAssertTrue(text.contains("[REDACTED]"))
  }

  private func makeModel(store: SettingsStoreSpy) -> AppModel {
    let snapshot = Self.makeSnapshot()
    return AppModel(
      snapshot: snapshot,
      refresh: { reason in
        store.events.append("refresh:\(Self.reasonName(reason))")
        return Self.makeSnapshot(states: store.providerStates)
      },
      settings: store.actions
    )
  }

  private static func reasonName(_ reason: RefreshReason) -> String {
    switch reason {
    case .launch: "launch"
    case .periodic: "periodic"
    case .popover: "popover"
    case .manual: "manual"
    case .providerEnabled(let provider): "providerEnabled:\(provider.rawValue)"
    }
  }

  private static func makeSnapshot(
    states: [ProviderID: StoredProviderState]? = nil,
    attempts: [ProviderID: [SourceAttempt]] = [:]
  ) -> RefreshSnapshot {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let providerStates =
      states
      ?? Dictionary(
        uniqueKeysWithValues: ProviderID.allCases.map {
          ($0, StoredProviderState(provider: $0, isEnabled: true))
        }
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
        now: now,
        window: MonthWindow(
          start: now,
          end: now.addingTimeInterval(30 * 24 * 60 * 60)
        ),
        hasAnyData: false,
        allDataIsStale: false
      ),
      attempts: attempts,
      allDataIsStale: false,
      refreshedAt: now,
      monthWindow: MonthWindow(
        start: now,
        end: now.addingTimeInterval(30 * 24 * 60 * 60)
      ),
      providerStates: providerStates,
      dataAvailability: .unavailable
    )
  }
}

@MainActor
private final class SettingsStoreSpy {
  var providerStates = Dictionary(
    uniqueKeysWithValues: ProviderID.allCases.map {
      ($0, StoredProviderState(provider: $0, isEnabled: true))
    }
  )
  var budgets: [BudgetDefinition] = []
  var alertBudgetIDs = Set<UUID>()
  var browserDiscoveryEnabled = true
  let localDiscoveryEnabled = true
  var failProviderSave = false
  var notificationAuthorizationRequests = 0
  var events: [String] = []

  var actions: AppSettingsActions {
    AppSettingsActions(
      loadBudgets: { self.budgets },
      saveProviderState: { state in
        self.events.append(
          "save-provider:\(state.provider.rawValue):\(state.isEnabled)"
        )
        if self.failProviderSave { throw SettingsStoreFailure.failed }
        self.providerStates[state.provider] = state
      },
      addBudget: { limit, now in
        guard limit.amount > 0 else { throw LedgerError.invalidBudget }
        guard !self.budgets.contains(where: { $0.limit == limit }) else {
          throw LedgerError.duplicateBudget
        }
        let budget = BudgetDefinition(
          id: UUID(),
          limit: limit,
          isEnabled: true,
          createdAt: now
        )
        self.budgets.append(budget)
        return budget
      },
      updateBudget: { replacement in
        guard
          let index = self.budgets.firstIndex(where: { $0.id == replacement.id })
        else {
          throw LedgerError.budgetNotFound
        }
        self.budgets[index] = replacement
      },
      removeBudget: { id in
        self.budgets.removeAll { $0.id == id }
        self.alertBudgetIDs.remove(id)
      },
      loadBrowserDiscoveryEnabled: { self.browserDiscoveryEnabled },
      saveBrowserDiscoveryEnabled: { self.browserDiscoveryEnabled = $0 },
      requestNotificationAuthorization: { previous, current in
        guard
          !previous.contains(where: \.isEnabled),
          current.contains(where: \.isEnabled)
        else {
          return false
        }
        self.notificationAuthorizationRequests += 1
        return true
      }
    )
  }
}

private enum SettingsStoreFailure: Error {
  case failed
}
