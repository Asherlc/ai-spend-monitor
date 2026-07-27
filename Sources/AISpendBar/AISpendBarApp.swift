import AISpendCore
import AISpendProviders
import AISpendUI
import AppKit
import Darwin
import SwiftData
import SwiftUI

@main
struct AISpendBarApp: App {
  @State private var model: AppModel
  private let lifecycle: AppLifecycleController

  init() {
    if CommandLine.arguments.contains("--self-check") {
      AppSelfCheck.runAndExit()
    }
    let model = AppEnvironment.makeModel()
    _model = State(initialValue: model)
    let lifecycle = AppLifecycleController(model: model)
    self.lifecycle = lifecycle
    lifecycle.start()
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
final class AppLifecycleController: NSObject {
  typealias RefreshAction =
    @MainActor @Sendable (RefreshReason) async -> Void
  typealias SleepAction =
    @Sendable (Duration) async throws -> Void
  typealias CancelAction =
    @MainActor @Sendable () -> Void

  private let interval: Duration
  private let refresh: RefreshAction
  private let sleep: SleepAction
  private let cancelRefresh: CancelAction
  private var loopTask: Task<Void, Never>?
  private var generation = 0

  var isRunning: Bool { loopTask != nil }

  init(
    interval: Duration = .seconds(15 * 60),
    refresh: @escaping RefreshAction,
    cancelRefresh: @escaping CancelAction = {},
    sleep: @escaping SleepAction = {
      try await ContinuousClock().sleep(for: $0)
    }
  ) {
    self.interval = interval
    self.refresh = refresh
    self.cancelRefresh = cancelRefresh
    self.sleep = sleep
    super.init()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(applicationWillTerminate),
      name: NSApplication.willTerminateNotification,
      object: nil
    )
  }

  convenience init(model: AppModel) {
    self.init(
      refresh: { [weak model] reason in
        switch reason {
        case .launch:
          await model?.launch()
        case .periodic:
          await model?.periodicRefresh()
        case .popover, .manual, .providerEnabled:
          break
        }
      },
      cancelRefresh: { [weak model] in
        model?.cancelActiveRefresh()
      }
    )
  }

  func start() {
    guard loopTask == nil else { return }
    generation += 1
    let activeGeneration = generation
    let interval = interval
    let refresh = refresh
    let sleep = sleep
    loopTask = Task { [weak self] in
      await refresh(.launch)
      while !Task.isCancelled {
        do {
          try await sleep(interval)
        } catch {
          break
        }
        guard !Task.isCancelled else { break }
        await refresh(.periodic)
      }
      self?.finish(generation: activeGeneration)
    }
  }

  func stop() {
    generation += 1
    loopTask?.cancel()
    loopTask = nil
    cancelRefresh()
  }

  @objc private func applicationWillTerminate() {
    stop()
  }

  private func finish(generation completedGeneration: Int) {
    guard generation == completedGeneration else { return }
    loopTask = nil
  }
}

private enum AppSelfCheck {
  static func runAndExit() -> Never {
    do {
      guard Bundle.main.bundleIdentifier == "com.ashercohen.AISpendBar",
        Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool == true,
        let executableURL = Bundle.main.executableURL,
        FileManager.default.isExecutableFile(atPath: executableURL.path),
        let resourceURL = Bundle.main.resourceURL,
        FileManager.default.fileExists(
          atPath:
            resourceURL
            .appendingPathComponent("AISpendBar_AISpendBar.bundle")
            .path
        )
      else {
        throw SelfCheckError.invalidBundle
      }
      _ = try PriceCatalog.bundled()
      write("AISpendBar self-check: OK\n", to: .standardOutput)
      exit(EXIT_SUCCESS)
    } catch {
      write("AISpendBar self-check: FAILED\n", to: .standardError)
      exit(EXIT_FAILURE)
    }
  }

  private static func write(_ message: String, to handle: FileHandle) {
    handle.write(Data(message.utf8))
  }
}

private enum SelfCheckError: Error {
  case invalidBundle
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
      ),
      storageURL: recovery.storageURL
    )
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
  private let browserDiscovery = BrowserDiscoveryPreference()
  let storageURL = AppStorageLocation.defaultLedgerURL

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
      let snapshot = await runtime.coordinator.refresh(reason: reason)
      return await runtime.alerts.process(snapshot: snapshot)
    } catch {
      return failureSnapshot()
    }
  }

  func records() throws -> [SpendRecord] {
    guard let runtime else { throw BootstrapError.runtimeUnavailable }
    let window = try MonthWindow.current(
      containing: runtime.clock.now,
      calendar: runtime.calendarProvider()
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
    browserDiscovery.isEnabled
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
    let schema = Schema([
      SpendRecordEntity.self,
      ProviderStateEntity.self,
      BudgetEntity.self,
      BudgetAlertStateEntity.self,
    ])
    let preparedStorageURL = try AppStorageLocation.prepareLedgerURL()
    let configuration = ModelConfiguration(
      schema: schema,
      url: preparedStorageURL
    )
    let container = try ModelContainer(
      for: schema,
      configurations: [configuration]
    )
    let repository = SwiftDataLedgerRepository(modelContainer: container)
    try AppEnvironment.installProviderDefaultsIfNeeded(in: repository)
    let catalog = try PriceCatalog.bundled()
    let adapters: [any ProviderAdapter] = [
      CursorAdapter(browserDiscovery: browserDiscovery),
      ClaudeAdapter(scanner: ClaudeLogScanner(priceCatalog: catalog)),
      OpenAIAdapter(scanner: CodexLogScanner(priceCatalog: catalog)),
    ]
    let clock = LiveClock()
    let calendarProvider: @Sendable () -> Calendar = {
      .autoupdatingCurrent
    }
    let coordinator = RefreshCoordinator(
      adapters: adapters,
      repository: repository,
      clock: clock,
      calendarProvider: calendarProvider
    )
    let alerts = BudgetAlertRuntime(
      repository: repository,
      deliver: { [notifications] decision in
        try await notifications.deliver(decision)
      }
    )
    return AppRuntime(
      repository: repository,
      coordinator: coordinator,
      alerts: alerts,
      clock: clock,
      calendarProvider: calendarProvider,
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
  let alerts: BudgetAlertRuntime
  let clock: LiveClock
  let calendarProvider: @Sendable () -> Calendar
  let browserDiscovery: BrowserDiscoveryPreference
}

private enum BootstrapError: Error {
  case runtimeUnavailable
}

private struct LiveClock: Clock {
  var now: Date { Date() }
}
