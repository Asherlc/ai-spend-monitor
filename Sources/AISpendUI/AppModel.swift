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
  public var selectedProvider: ProviderID?

  private let refreshAction: RefreshAction
  private let recordLoader: RecordLoader?

  public init(
    snapshot: RefreshSnapshot,
    refresh: @escaping RefreshAction,
    records: RecordLoader? = nil
  ) {
    self.snapshot = snapshot
    refreshAction = refresh
    recordLoader = records
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
    records: RecordLoader? = nil
  ) {
    self.init(
      snapshot: snapshot,
      refresh: { reason in await coordinator.refresh(reason: reason) },
      records: records
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
