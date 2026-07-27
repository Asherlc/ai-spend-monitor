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
      Task10SettingsPlaceholder()
    }
  }
}

private struct Task10SettingsPlaceholder: View {
  var body: some View {
    ContentUnavailableView(
      "Settings",
      systemImage: "gearshape",
      description: Text("Provider, budget, and privacy controls are being configured.")
    )
    .frame(width: 480, height: 320)
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
      records: recovery.records
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
      hasCurrentMonthData: false
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
    let adapters: [any ProviderAdapter] = [
      CursorAdapter(),
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
      clock: clock
    )
  }
}

@MainActor
private struct AppRuntime {
  let repository: SwiftDataLedgerRepository
  let coordinator: RefreshCoordinator
  let clock: LiveClock
}

private enum BootstrapError: Error {
  case runtimeUnavailable
}

private struct LiveClock: Clock {
  var now: Date { Date() }
}
