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
    self.records = (try? records?()) ?? []
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
    let amount = SpendFormatting.menuBar(snapshot.summary.total)
    return needsAttention ? "\(amount) !" : amount
  }

  public var statusSymbol: String {
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
    SpendFormatting.month(snapshot.refreshedAt)
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

  public var selectedProviderSummary: ProviderSpendSummary? {
    guard let selectedProvider else { return nil }
    return providerSummaries.first { $0.id == selectedProvider }
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
      records = (try? recordLoader()) ?? records
    }
    if let selectedProvider,
      !snapshot.summary.providers.contains(where: { $0.id == selectedProvider })
    {
      self.selectedProvider = nil
    }
  }
}
