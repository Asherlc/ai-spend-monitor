import AISpendCore
import Foundation
import Observation

public struct DailySpendPoint: Identifiable, Hashable, Sendable {
  public let date: Date
  public let amount: Money

  public var id: Date { date }

  public init(date: Date, amount: Money) {
    self.date = date
    self.amount = amount
  }
}

public enum SpendAvailability: Hashable, Sendable {
  case available
  case collecting
  case unavailable
}

public enum ProviderFreshnessStatus: Hashable, Sendable {
  case fresh
  case stale(age: TimeInterval)
  case cachedAfterFailure(age: TimeInterval, message: String)
  case unavailable(message: String)
}

public struct ProviderStatus: Hashable, Sendable {
  public let lastAttemptAt: Date?
  public let lastSuccessfulAt: Date?
  public let freshness: ProviderFreshnessStatus
}

public struct ProviderPresentation: Identifiable, Hashable, Sendable {
  public let summary: ProviderSpendSummary
  public let status: ProviderStatus
  public let attempts: [SourceAttempt]
  public let availability: CurrentMonthDataAvailability

  public var id: ProviderID { summary.id }

  public var amountTitle: String {
    availability == .available
      ? SpendFormatting.currency(summary.total)
      : "No data"
  }
}

public enum BudgetValidationResult: Equatable, Sendable {
  case success
  case validationError(String)
  case persistenceError(String)
}

public struct ProviderSettingPresentation: Identifiable, Hashable, Sendable {
  public let id: ProviderID
  public let displayName: String
  public let isEnabled: Bool
  public let status: ProviderStatus
  public let activeSources: [String]
}

public struct ProviderDiagnosticEntry: Identifiable, Hashable, Sendable {
  public let strategyID: String
  public let outcome: String
  public let detail: String

  public var id: String { "\(strategyID):\(outcome):\(detail)" }
}

@MainActor
public struct AppSettingsActions {
  let loadBudgets: () throws -> [BudgetDefinition]
  let saveProviderState: (StoredProviderState) throws -> Void
  let addBudget: (Money, Date) throws -> BudgetDefinition
  let updateBudget: (BudgetDefinition) throws -> Void
  let removeBudget: (UUID) throws -> Void
  let loadBrowserDiscoveryEnabled: () -> Bool
  let saveBrowserDiscoveryEnabled: (Bool) throws -> Void
  let requestNotificationAuthorization:
    ([BudgetDefinition], [BudgetDefinition]) async throws -> Bool

  public init(
    loadBudgets: @escaping () throws -> [BudgetDefinition],
    saveProviderState: @escaping (StoredProviderState) throws -> Void,
    addBudget: @escaping (Money, Date) throws -> BudgetDefinition,
    updateBudget: @escaping (BudgetDefinition) throws -> Void,
    removeBudget: @escaping (UUID) throws -> Void,
    loadBrowserDiscoveryEnabled: @escaping () -> Bool,
    saveBrowserDiscoveryEnabled: @escaping (Bool) throws -> Void,
    requestNotificationAuthorization:
      @escaping ([BudgetDefinition], [BudgetDefinition]) async throws -> Bool
  ) {
    self.loadBudgets = loadBudgets
    self.saveProviderState = saveProviderState
    self.addBudget = addBudget
    self.updateBudget = updateBudget
    self.removeBudget = removeBudget
    self.loadBrowserDiscoveryEnabled = loadBrowserDiscoveryEnabled
    self.saveBrowserDiscoveryEnabled = saveBrowserDiscoveryEnabled
    self.requestNotificationAuthorization = requestNotificationAuthorization
  }

  public static let unavailable = AppSettingsActions(
    loadBudgets: { [] },
    saveProviderState: { _ in throw AppSettingsError.unavailable },
    addBudget: { _, _ in throw AppSettingsError.unavailable },
    updateBudget: { _ in throw AppSettingsError.unavailable },
    removeBudget: { _ in throw AppSettingsError.unavailable },
    loadBrowserDiscoveryEnabled: { true },
    saveBrowserDiscoveryEnabled: { _ in throw AppSettingsError.unavailable },
    requestNotificationAuthorization: { _, _ in false }
  )
}

@MainActor
@Observable
public final class AppModel {
  public typealias RefreshAction =
    @MainActor @Sendable (RefreshReason) async -> RefreshSnapshot
  public typealias RecordLoader =
    @MainActor @Sendable () throws -> [SpendRecord]

  public private(set) var snapshot: RefreshSnapshot
  public private(set) var isRefreshing = false
  public private(set) var records: [SpendRecord] = []
  public private(set) var dailyHistoryUnavailable = false
  public private(set) var budgets: [BudgetDefinition] = []
  public private(set) var browserDiscoveryEnabled = true
  public private(set) var settingsError: String?
  public var selectedProvider: ProviderID?

  private let refreshAction: RefreshAction
  private let recordLoader: RecordLoader?
  private let settingsActions: AppSettingsActions
  private let now: () -> Date

  public init(
    snapshot: RefreshSnapshot,
    refresh: @escaping RefreshAction,
    records: RecordLoader? = nil,
    settings: AppSettingsActions = .unavailable,
    now: @escaping () -> Date = Date.init
  ) {
    self.snapshot = snapshot
    refreshAction = refresh
    recordLoader = records
    settingsActions = settings
    self.now = now
    browserDiscoveryEnabled = settings.loadBrowserDiscoveryEnabled()
    do {
      budgets = try settings.loadBudgets().sorted(by: Self.budgetOrder)
    } catch {
      settingsError = "Budgets could not be loaded."
    }
    if let records {
      do {
        self.records = try records()
      } catch {
        self.records = []
        dailyHistoryUnavailable = true
      }
    }
  }

  public convenience init(
    snapshot: RefreshSnapshot,
    coordinator: RefreshCoordinator,
    records: RecordLoader? = nil,
    settings: AppSettingsActions = .unavailable,
    now: @escaping () -> Date = Date.init
  ) {
    self.init(
      snapshot: snapshot,
      refresh: { reason in await coordinator.refresh(reason: reason) },
      records: records,
      settings: settings,
      now: now
    )
  }

  public func launch() async {
    await performRefresh(reason: .launch)
  }

  public func popoverOpened() async {
    await performRefresh(reason: .popover)
  }

  public func refresh() async {
    await performRefresh(reason: .manual)
  }

  public var statusTitle: String {
    guard availability != .unavailable else { return "No data" }
    let amount = SpendFormatting.menuBar(snapshot.summary.total)
    return needsAttention ? "\(amount) !" : amount
  }

  public var headlineTitle: String {
    availability == .unavailable
      ? "No current data"
      : SpendFormatting.currency(snapshot.summary.total)
  }

  public var availability: SpendAvailability {
    guard snapshot.dataAvailability == .available else { return .unavailable }
    return snapshot.pacing.isCollecting ? .collecting : .available
  }

  public var statusSymbol: String {
    if availability == .unavailable {
      return "questionmark.circle"
    }
    if snapshot.allDataIsStale {
      return "exclamationmark.triangle.fill"
    }
    if snapshot.summary.isPartial {
      return "dollarsign.circle.fill"
    }
    return "dollarsign.circle"
  }

  public var needsAttention: Bool {
    snapshot.summary.isPartial || snapshot.allDataIsStale
  }

  public var monthTitle: String {
    SpendFormatting.month(snapshot.monthWindow.start)
  }

  public var budgetEvaluations: [BudgetEvaluation] {
    snapshot.pacing.budgets.sorted { $0.limit < $1.limit }
  }

  public var providerSummaries: [ProviderSpendSummary] {
    snapshot.summary.providers.sorted {
      if $0.total != $1.total { return $0.total > $1.total }
      return $0.id.rawValue < $1.id.rawValue
    }
  }

  public var providerRows: [ProviderPresentation] {
    let summaries = Dictionary(
      uniqueKeysWithValues: providerSummaries.map { ($0.id, $0) }
    )
    let enabledProviders: Set<ProviderID>
    if snapshot.providerStates.isEmpty {
      enabledProviders = Set(summaries.keys)
    } else {
      enabledProviders = Set(
        snapshot.providerStates.values.filter(\.isEnabled).map(\.provider)
      )
    }
    return enabledProviders.map { provider in
      let summary = summaries[provider] ?? Self.emptySummary(provider: provider)
      return ProviderPresentation(
        summary: summary,
        status: providerStatus(
          state: snapshot.providerStates[provider],
          attempts: snapshot.attempts[provider] ?? []
        ),
        attempts: snapshot.attempts[provider] ?? [],
        availability: snapshot.providerAvailability[provider]
          ?? (summaries[provider] == nil ? .unavailable : .available)
      )
    }.sorted {
      if $0.summary.total != $1.summary.total {
        return $0.summary.total > $1.summary.total
      }
      return $0.id.rawValue < $1.id.rawValue
    }
  }

  public var selectedProviderSummary: ProviderSpendSummary? {
    guard let selectedProvider else { return nil }
    return providerRows.first { $0.id == selectedProvider }?.summary
  }

  public var selectedProviderPresentation: ProviderPresentation? {
    guard let selectedProvider else { return nil }
    return providerRows.first { $0.id == selectedProvider }
  }

  public func providerShare(_ provider: ProviderSpendSummary) -> Decimal {
    guard snapshot.summary.total.amount > 0 else { return 0 }
    return provider.total.amount / snapshot.summary.total.amount
  }

  public func dailySpend(for provider: ProviderID) -> [DailySpendPoint] {
    let calendar = Calendar.current
    let providerRecords = records.filter { $0.provider == provider }
    let reconciled = SpendReconciler().reconcile(providerRecords).included
    let grouped = Dictionary(
      grouping: reconciled
    ) { calendar.startOfDay(for: $0.intervalStart) }
    return grouped.map { date, records in
      DailySpendPoint(
        date: date,
        amount: records.reduce(.zero) { $0 + $1.amount }
      )
    }.sorted { $0.date < $1.date }
  }

  public func attempts(for provider: ProviderID) -> [SourceAttempt] {
    snapshot.attempts[provider] ?? []
  }

  public var providerSettings: [ProviderSettingPresentation] {
    ProviderDescriptor.builtIns.map { descriptor in
      let state = snapshot.providerStates[descriptor.id]
      let attempts = attempts(for: descriptor.id)
      return ProviderSettingPresentation(
        id: descriptor.id,
        displayName: descriptor.displayName,
        isEnabled: state?.isEnabled ?? true,
        status: providerStatus(state: state, attempts: attempts),
        activeSources: attempts.compactMap { attempt in
          if case .succeeded = attempt.outcome { return attempt.strategyID }
          return nil
        }
      )
    }
  }

  public func diagnosticEntries(
    for provider: ProviderID
  ) -> [ProviderDiagnosticEntry] {
    let sanitizer = DiagnosticSanitizer()
    return attempts(for: provider).map { attempt in
      switch attempt.outcome {
      case .succeeded(let recordCount):
        ProviderDiagnosticEntry(
          strategyID: attempt.strategyID,
          outcome: "Succeeded",
          detail: "\(recordCount) records"
        )
      case .unavailable(let reason):
        ProviderDiagnosticEntry(
          strategyID: attempt.strategyID,
          outcome: "Unavailable",
          detail: sanitizer.sanitize(reason)
        )
      case .failed(let message):
        ProviderDiagnosticEntry(
          strategyID: attempt.strategyID,
          outcome: "Failed",
          detail: sanitizer.sanitize(message)
        )
      }
    }
  }

  public func setProvider(_ provider: ProviderID, enabled: Bool) async {
    settingsError = nil
    let prior =
      snapshot.providerStates[provider]
      ?? StoredProviderState(provider: provider, isEnabled: !enabled)
    let replacement = StoredProviderState(
      provider: provider,
      isEnabled: enabled,
      lastAttemptAt: prior.lastAttemptAt,
      lastSuccessfulAt: prior.lastSuccessfulAt,
      refreshStatus: prior.refreshStatus,
      lastFailureMessage: prior.lastFailureMessage
    )
    do {
      try settingsActions.saveProviderState(replacement)
    } catch {
      settingsError = "The provider setting could not be saved."
      return
    }
    await performRefresh(reason: enabled ? .providerEnabled(provider) : .manual)
  }

  public func addBudget(
    decimalText: String
  ) async -> BudgetValidationResult {
    guard let amount = Self.parsePositiveDecimal(decimalText) else {
      return validationFailure("Enter a positive USD amount using a decimal point.")
    }
    guard !budgets.contains(where: { $0.limit.amount == amount }) else {
      return validationFailure("A budget with that amount already exists.")
    }
    let previousBudgets = budgets
    do {
      _ = try settingsActions.addBudget(Money(amount), now())
      try reloadBudgets()
      await requestNotificationAuthorization(
        previousBudgets: previousBudgets,
        currentBudgets: budgets
      )
      await performRefresh(reason: .manual)
      return .success
    } catch LedgerError.duplicateBudget {
      return validationFailure("A budget with that amount already exists.")
    } catch LedgerError.invalidBudget {
      return validationFailure("Enter a positive USD amount.")
    } catch {
      return persistenceFailure("The budget could not be saved.")
    }
  }

  public func updateBudget(
    _ budget: BudgetDefinition
  ) async -> BudgetValidationResult {
    guard budget.limit.currency == "USD", budget.limit.amount > 0 else {
      return validationFailure("Enter a positive USD amount.")
    }
    guard
      !budgets.contains(where: {
        $0.id != budget.id && $0.limit.amount == budget.limit.amount
      })
    else {
      return validationFailure("A budget with that amount already exists.")
    }
    let previousBudgets = budgets
    do {
      try settingsActions.updateBudget(budget)
      try reloadBudgets()
      await requestNotificationAuthorization(
        previousBudgets: previousBudgets,
        currentBudgets: budgets
      )
      await performRefresh(reason: .manual)
      return .success
    } catch LedgerError.duplicateBudget {
      return validationFailure("A budget with that amount already exists.")
    } catch LedgerError.invalidBudget {
      return validationFailure("Enter a positive USD amount.")
    } catch {
      return persistenceFailure("The budget could not be saved.")
    }
  }

  public func removeBudget(id: UUID) async {
    do {
      try settingsActions.removeBudget(id)
      try reloadBudgets()
      settingsError = nil
      await performRefresh(reason: .manual)
    } catch {
      settingsError = "The budget could not be removed."
    }
  }

  public func setBrowserDiscoveryEnabled(_ enabled: Bool) async {
    do {
      try settingsActions.saveBrowserDiscoveryEnabled(enabled)
      browserDiscoveryEnabled = settingsActions.loadBrowserDiscoveryEnabled()
      settingsError = nil
      await performRefresh(reason: .manual)
    } catch {
      settingsError = "The browser discovery setting could not be saved."
    }
  }

  private func performRefresh(reason: RefreshReason) async {
    guard !isRefreshing else { return }
    isRefreshing = true
    defer { isRefreshing = false }
    snapshot = await refreshAction(reason)
    if let recordLoader {
      do {
        records = try recordLoader()
        dailyHistoryUnavailable = false
      } catch {
        records = []
        dailyHistoryUnavailable = true
      }
    }
    if let selectedProvider,
      !providerRows.contains(where: { $0.id == selectedProvider })
    {
      self.selectedProvider = nil
    }
  }

  private func reloadBudgets() throws {
    budgets = try settingsActions.loadBudgets().sorted(by: Self.budgetOrder)
  }

  private func requestNotificationAuthorization(
    previousBudgets: [BudgetDefinition],
    currentBudgets: [BudgetDefinition]
  ) async {
    do {
      _ = try await settingsActions.requestNotificationAuthorization(
        previousBudgets,
        currentBudgets
      )
      settingsError = nil
    } catch {
      settingsError =
        "The budget was saved, but notification permission could not be requested."
    }
  }

  private func validationFailure(_ message: String) -> BudgetValidationResult {
    settingsError = message
    return .validationError(message)
  }

  private func persistenceFailure(_ message: String) -> BudgetValidationResult {
    settingsError = message
    return .persistenceError(message)
  }

  private static func parsePositiveDecimal(_ text: String) -> Decimal? {
    guard
      text.range(
        of: #"^[0-9]+(?:\.[0-9]+)?$"#,
        options: .regularExpression
      ) != nil,
      let value = Decimal(
        string: text,
        locale: Locale(identifier: "en_US_POSIX")
      ),
      value > 0
    else {
      return nil
    }
    return value
  }

  private static func budgetOrder(
    _ lhs: BudgetDefinition,
    _ rhs: BudgetDefinition
  ) -> Bool {
    if lhs.limit != rhs.limit { return lhs.limit < rhs.limit }
    return lhs.id.uuidString < rhs.id.uuidString
  }

  private func providerStatus(
    state: StoredProviderState?,
    attempts: [SourceAttempt]
  ) -> ProviderStatus {
    guard let state else {
      let message = firstProblem(in: attempts) ?? "Provider has not refreshed"
      return ProviderStatus(
        lastAttemptAt: nil,
        lastSuccessfulAt: nil,
        freshness: .unavailable(message: message)
      )
    }
    let failure = state.lastFailureMessage ?? firstProblem(in: attempts)
    if state.refreshStatus == .failed {
      if let success = state.lastSuccessfulAt {
        return ProviderStatus(
          lastAttemptAt: state.lastAttemptAt,
          lastSuccessfulAt: success,
          freshness: .cachedAfterFailure(
            age: max(0, snapshot.evaluatedAt.timeIntervalSince(success)),
            message: failure ?? "Provider refresh failed"
          )
        )
      }
      return ProviderStatus(
        lastAttemptAt: state.lastAttemptAt,
        lastSuccessfulAt: nil,
        freshness: .unavailable(message: failure ?? "Provider refresh failed")
      )
    }
    guard let success = state.lastSuccessfulAt else {
      return ProviderStatus(
        lastAttemptAt: state.lastAttemptAt,
        lastSuccessfulAt: nil,
        freshness: .unavailable(message: "Provider has not refreshed")
      )
    }
    let age = max(0, snapshot.evaluatedAt.timeIntervalSince(success))
    return ProviderStatus(
      lastAttemptAt: state.lastAttemptAt,
      lastSuccessfulAt: success,
      freshness: age > 30 * 60 ? .stale(age: age) : .fresh
    )
  }

  private func firstProblem(in attempts: [SourceAttempt]) -> String? {
    attempts.lazy.compactMap { attempt in
      switch attempt.outcome {
      case .succeeded: nil
      case .unavailable(let reason): reason
      case .failed(let message): message
      }
    }.first
  }

  private static func emptySummary(
    provider: ProviderID
  ) -> ProviderSpendSummary {
    ProviderSpendSummary(
      id: provider,
      actual: .zero,
      estimated: .zero,
      models: []
    )
  }
}

private enum AppSettingsError: Error {
  case unavailable
}
