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
    do {
      let container = try ModelContainer(
        for:
          SpendRecordEntity.self,
        ProviderStateEntity.self,
        BudgetEntity.self,
        BudgetAlertStateEntity.self
      )
      let repository = SwiftDataLedgerRepository(modelContainer: container)
      try installProviderDefaultsIfNeeded(in: repository)

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
      let snapshot = try coordinator.cachedSnapshot()
      let model = AppModel(
        snapshot: snapshot,
        coordinator: coordinator,
        records: {
          let window = try MonthWindow.current(
            containing: clock.now,
            calendar: .current
          )
          return try repository.records(in: window)
        }
      )
      Task { await model.launch() }
      return model
    } catch {
      return fallbackModel()
    }
  }

  private static func installProviderDefaultsIfNeeded(
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

  private static func fallbackModel() -> AppModel {
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
    let snapshot = RefreshSnapshot(
      summary: summary,
      pacing: pacing,
      attempts: [:],
      allDataIsStale: true,
      refreshedAt: now
    )
    return AppModel(snapshot: snapshot, refresh: { _ in snapshot })
  }
}

private struct LiveClock: Clock {
  var now: Date { Date() }
}
