import AISpendCore
import AISpendProviders
import AISpendUI
import SwiftData
import SwiftUI

@main
struct AISpendBarApp: App {
  @State private var model: AppModel

  init() {
    _model = State(initialValue: AppEnvironment.makeModel())
  }

  var body: some Scene {
    MenuBarExtra {
      SpendPopoverView(model: model)
    } label: {
      Label(model.statusTitle, systemImage: model.statusSymbol)
    }
    .menuBarExtraStyle(.window)

    Settings {
      SettingsView(model: model)
    }
  }
}

@MainActor
private enum AppEnvironment {
  static func makeModel() -> AppModel {
    let recovery = BootstrapRecovery()
    let initialSnapshot: RefreshSnapshot
    do {
      initialSnapshot = try recovery.prepare()
    } catch {
      initialSnapshot = recovery.failureSnapshot()
    }
    let model = AppModel(
      snapshot: initialSnapshot,
      refresh: recovery.refresh,
      records: recovery.records,
      settings: AppSettingsActions(
        loadBudgets: recovery.budgets,
        saveProviderState: recovery.saveProviderState,
        addBudget: recovery.addBudget,
        updateBudget: recovery.updateBudget,
        removeBudget: recovery.removeBudget,
        loadBrowserDiscoveryEnabled: recovery.browserDiscoveryEnabled,
        saveBrowserDiscoveryEnabled: recovery.saveBrowserDiscoveryEnabled,
        requestNotificationAuthorization: recovery.requestNotificationAuthorization
      )
    )
    Task { await model.launch() }
    return model
  }

  static func installProviderDefaultsIfNeeded(
    in repository: SwiftDataLedgerRepository
  ) throws {
    guard try repository.providerStates().isEmpty else { return }
    for descriptor in ProviderDescriptor.builtIns {
      try repository.saveProviderState(
        StoredProviderState(
          provider: descriptor.id,
          isEnabled: true
        )
      )
    }
  }
}

@MainActor
private final class BootstrapRecovery {
  private var runtime: AppRuntime?
  private let notifications = BudgetNotificationClient()

  func prepare() throws -> RefreshSnapshot {
    let runtime = try makeRuntime()
    self.runtime = runtime
    return try runtime.coordinator.cachedSnapshot()
  }

  func refresh(reason: RefreshReason) async -> RefreshSnapshot {
    do {
      let runtime: AppRuntime
      if let existing = self.runtime {
        runtime = existing
      } else {
        runtime = try makeRuntime()
        self.runtime = runtime
      }
      return await runtime.coordinator.refresh(reason: reason)
    } catch {
      return failureSnapshot()
    }
  }

  func records() throws -> [SpendRecord] {
    guard let runtime else { throw BootstrapError.runtimeUnavailable }
    let window = try MonthWindow.current(
      containing: runtime.clock.now,
      calendar: .current
    )
    return try runtime.repository.records(in: window)
  }

  func budgets() throws -> [BudgetDefinition] {
    try requiredRuntime().repository.budgets()
  }

  func saveProviderState(_ state: StoredProviderState) throws {
    try requiredRuntime().repository.saveProviderState(state)
  }

  func addBudget(limit: Money, now: Date) throws -> BudgetDefinition {
    try requiredRuntime().repository.addBudget(limit: limit, now: now)
  }

  func updateBudget(_ budget: BudgetDefinition) throws {
    try requiredRuntime().repository.updateBudget(budget)
  }

  func removeBudget(id: UUID) throws {
    try requiredRuntime().repository.removeBudget(id: id)
  }

  func browserDiscoveryEnabled() -> Bool {
    runtime?.browserDiscovery.isEnabled ?? true
  }

  func saveBrowserDiscoveryEnabled(_ enabled: Bool) throws {
    (try requiredRuntime()).browserDiscovery.isEnabled = enabled
  }

  func requestNotificationAuthorization(
    previousBudgets: [BudgetDefinition],
    currentBudgets: [BudgetDefinition]
  ) async throws -> Bool {
    try await notifications.requestAuthorizationIfFirstEnabledBudget(
      previousBudgets: previousBudgets,
      currentBudgets: currentBudgets
    )
  }

  func failureSnapshot() -> RefreshSnapshot {
    let now = Date()
    let window =
      (try? MonthWindow.current(containing: now, calendar: .current))
      ?? MonthWindow(start: now, end: now.addingTimeInterval(1))
    let summary = MonthlySummary(
      total: .zero,
      actual: .zero,
      estimated: .zero,
      providers: [],
      isPartial: true
    )
    let pacing = PacingEngine().evaluate(
      spend: .zero,
      budgets: [],
      now: now,
      window: window,
      hasAnyData: false,
      allDataIsStale: true,
      isPartial: true
    )
    let message = "App storage or bundled pricing could not be initialized. Refresh to retry."
    let states = Dictionary(
      uniqueKeysWithValues: ProviderID.allCases.map {
        (
          $0,
          StoredProviderState(
            provider: $0,
            isEnabled: true,
            lastAttemptAt: now,
            refreshStatus: .failed,
            lastFailureMessage: message
          )
        )
      }
    )
    let attempts = Dictionary(
      uniqueKeysWithValues: ProviderID.allCases.map {
        (
          $0,
          [
            SourceAttempt(
              strategyID: "bootstrap",
              outcome: .failed(redactedMessage: message)
            )
          ]
        )
      }
    )
    let snapshot = RefreshSnapshot(
      summary: summary,
      pacing: pacing,
      attempts: attempts,
      allDataIsStale: true,
      refreshedAt: now,
      monthWindow: window,
      providerStates: states,
      dataAvailability: .unavailable,
      providerAvailability: Dictionary(
        uniqueKeysWithValues: ProviderID.allCases.map { ($0, .unavailable) }
      )
    )
    return snapshot
  }

  private func makeRuntime() throws -> AppRuntime {
    let container = try ModelContainer(
      for:
        SpendRecordEntity.self,
      ProviderStateEntity.self,
      BudgetEntity.self,
      BudgetAlertStateEntity.self
    )
    let repository = SwiftDataLedgerRepository(modelContainer: container)
    try AppEnvironment.installProviderDefaultsIfNeeded(in: repository)
    let catalog = try PriceCatalog.bundled()
    let browserDiscovery = BrowserDiscoveryPreference()
    let adapters: [any ProviderAdapter] = [
      CursorAdapter(browserDiscovery: browserDiscovery),
      ClaudeAdapter(scanner: ClaudeLogScanner(priceCatalog: catalog)),
      OpenAIAdapter(scanner: CodexLogScanner(priceCatalog: catalog)),
    ]
    let clock = LiveClock()
    let coordinator = RefreshCoordinator(
      adapters: adapters,
      repository: repository,
      clock: clock
    )
    return AppRuntime(
      repository: repository,
      coordinator: coordinator,
      clock: clock,
      browserDiscovery: browserDiscovery
    )
  }

  private func requiredRuntime() throws -> AppRuntime {
    if let runtime { return runtime }
    let runtime = try makeRuntime()
    self.runtime = runtime
    return runtime
  }
}

@MainActor
private struct AppRuntime {
  let repository: SwiftDataLedgerRepository
  let coordinator: RefreshCoordinator
  let clock: LiveClock
  let browserDiscovery: BrowserDiscoveryPreference
}

private enum BootstrapError: Error {
  case runtimeUnavailable
}

private struct LiveClock: Clock {
  var now: Date { Date() }
}
