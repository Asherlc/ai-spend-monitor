import Foundation

public enum RefreshReason: Hashable, Sendable {
  case launch
  case periodic
  case popover
  case manual
  case providerEnabled(ProviderID)
}

public struct RefreshSnapshot: Sendable {
  public let summary: MonthlySummary
  public let pacing: PacingResult
  public let attempts: [ProviderID: [SourceAttempt]]
  public let refreshedAt: Date

  public init(
    summary: MonthlySummary,
    pacing: PacingResult,
    attempts: [ProviderID: [SourceAttempt]],
    refreshedAt: Date
  ) {
    self.summary = summary
    self.pacing = pacing
    self.attempts = attempts
    self.refreshedAt = refreshedAt
  }
}

public typealias ProviderTimeout =
  @Sendable (
    _ timeout: TimeInterval,
    _ operation: ProviderOperation
  ) async throws -> ProviderFetchResult

public enum ProviderTimeoutError: Error, Sendable {
  case timedOut
}

public struct ProviderOperation: Sendable {
  private let operation: @Sendable () async throws -> ProviderFetchResult

  public init(
    _ operation: @escaping @Sendable () async throws -> ProviderFetchResult
  ) {
    self.operation = operation
  }

  public func callAsFunction() async throws -> ProviderFetchResult {
    try await operation()
  }
}

@MainActor
public final class RefreshCoordinator {
  public private(set) var lastRefreshReason: RefreshReason?

  private let adapters: [any ProviderAdapter]
  private let repository: any LedgerRepository
  private let reconciler: SpendReconciler
  private let aggregator: SpendAggregator
  private let pacingEngine: PacingEngine
  private let clock: any Clock
  private let calendar: Calendar
  private let timeout: TimeInterval
  private let runWithTimeout: ProviderTimeout
  private let sanitizer: DiagnosticSanitizer
  private var lastSnapshot: RefreshSnapshot?

  public init(
    adapters: [any ProviderAdapter],
    repository: any LedgerRepository,
    reconciler: SpendReconciler = SpendReconciler(),
    aggregator: SpendAggregator = SpendAggregator(),
    pacingEngine: PacingEngine = PacingEngine(),
    clock: any Clock,
    calendar: Calendar = .current,
    timeout: TimeInterval = 20,
    withTimeout: @escaping ProviderTimeout = RefreshCoordinator.withTimeout,
    sanitizer: DiagnosticSanitizer = DiagnosticSanitizer()
  ) {
    self.adapters = adapters
    self.repository = repository
    self.reconciler = reconciler
    self.aggregator = aggregator
    self.pacingEngine = pacingEngine
    self.clock = clock
    self.calendar = calendar
    self.timeout = timeout
    runWithTimeout = withTimeout
    self.sanitizer = sanitizer
  }

  public func refresh(reason: RefreshReason) async -> RefreshSnapshot {
    lastRefreshReason = reason
    let now = clock.now
    let initialStates = (try? repository.providerStates()) ?? [:]

    if reason == .popover,
      let lastAttemptAt = initialStates.values.compactMap(\.lastAttemptAt).max(),
      now.timeIntervalSince(lastAttemptAt) < 60,
      let snapshot = try? cachedSnapshot()
    {
      return snapshot
    }

    guard let window = try? MonthWindow.current(containing: now, calendar: calendar) else {
      return fallbackSnapshot(at: now)
    }

    let enabledProviders = Set(
      initialStates.values.filter(\.isEnabled).map(\.provider)
    )
    let enabledAdapters = adapters.filter {
      enabledProviders.contains($0.provider)
    }
    let timeout = timeout
    let runWithTimeout = runWithTimeout
    let outcomes = await withTaskGroup(
      of: AdapterOutcome.self,
      returning: [AdapterOutcome].self
    ) { group in
      for adapter in enabledAdapters {
        group.addTask {
          do {
            let result = try await runWithTimeout(
              timeout,
              ProviderOperation {
                try await adapter.fetch(window: window)
              }
            )
            guard result.provider == adapter.provider else {
              return .failure(
                provider: adapter.provider,
                message: "Provider returned records for a different provider"
              )
            }
            return .success(result)
          } catch is CancellationError {
            return .cancelled(provider: adapter.provider)
          } catch ProviderTimeoutError.timedOut {
            return .failure(
              provider: adapter.provider,
              message: "Provider refresh timed out"
            )
          } catch {
            return .failure(
              provider: adapter.provider,
              message: String(describing: error)
            )
          }
        }
      }

      var collected: [AdapterOutcome] = []
      for await outcome in group {
        collected.append(outcome)
      }
      return collected
    }

    if Task.isCancelled {
      return (try? cachedSnapshot()) ?? fallbackSnapshot(at: now)
    }

    var states = initialStates
    var attempts: [ProviderID: [SourceAttempt]] = [:]
    for outcome in outcomes {
      switch outcome {
      case .success(let result):
        let provider = result.provider
        do {
          try persist(result: result, in: window)
          let previous = states[provider]
          let state = StoredProviderState(
            provider: provider,
            isEnabled: previous?.isEnabled ?? true,
            lastAttemptAt: now,
            lastSuccessfulAt: now,
            refreshStatus: .success,
            lastFailureMessage: nil
          )
          try repository.saveProviderState(state)
          states[provider] = state
          attempts[provider] = sanitize(result.attempts)
        } catch {
          recordFailure(
            provider: provider,
            message: String(describing: error),
            now: now,
            states: &states,
            attempts: &attempts
          )
        }
      case .failure(let provider, let message):
        recordFailure(
          provider: provider,
          message: message,
          now: now,
          states: &states,
          attempts: &attempts
        )
      case .cancelled:
        break
      }
    }

    let snapshot = makeSnapshot(
      window: window,
      enabledProviders: enabledProviders,
      states: states,
      attempts: attempts,
      refreshedAt: now
    )
    lastSnapshot = snapshot
    return snapshot
  }

  public func cachedSnapshot() throws -> RefreshSnapshot {
    if let lastSnapshot {
      return lastSnapshot
    }

    let now = clock.now
    let states = try repository.providerStates()
    let enabledProviders = Set(
      states.values.filter(\.isEnabled).map(\.provider)
    )
    let window = try MonthWindow.current(containing: now, calendar: calendar)
    let attempts = states.reduce(into: [ProviderID: [SourceAttempt]]()) {
      result,
      entry in
      guard
        entry.value.refreshStatus == .failed,
        let message = entry.value.lastFailureMessage
      else {
        return
      }
      result[entry.key] = [
        SourceAttempt(
          strategyID: "refresh",
          outcome: .failed(redactedMessage: sanitizer.sanitize(message))
        )
      ]
    }
    let refreshedAt = states.values.compactMap(\.lastAttemptAt).max() ?? now
    return makeSnapshot(
      window: window,
      enabledProviders: enabledProviders,
      states: states,
      attempts: attempts,
      refreshedAt: refreshedAt
    )
  }

  public nonisolated static func withTimeout(
    _ timeout: TimeInterval,
    _ operation: ProviderOperation
  ) async throws -> ProviderFetchResult {
    try await withThrowingTaskGroup(of: ProviderFetchResult.self) { group in
      group.addTask {
        try await operation()
      }
      group.addTask {
        try await Task.sleep(for: .seconds(timeout))
        try Task.checkCancellation()
        throw ProviderTimeoutError.timedOut
      }
      defer {
        group.cancelAll()
      }
      guard let result = try await group.next() else {
        throw CancellationError()
      }
      return result
    }
  }

  private func persist(
    result: ProviderFetchResult,
    in window: MonthWindow
  ) throws {
    guard result.records.allSatisfy({ $0.provider == result.provider }) else {
      throw RefreshCoordinatorError.providerMismatch
    }
    let sourceIDs = Set(result.records.map(\.sourceID))
    let reconciled = reconciler.reconcile(result.records)
    let recordsBySource = Dictionary(grouping: reconciled.included, by: \.sourceID)
    for sourceID in sourceIDs {
      try repository.replace(
        records: recordsBySource[sourceID, default: []],
        provider: result.provider,
        sourceID: sourceID,
        interval: window
      )
    }
  }

  private func recordFailure(
    provider: ProviderID,
    message: String,
    now: Date,
    states: inout [ProviderID: StoredProviderState],
    attempts: inout [ProviderID: [SourceAttempt]]
  ) {
    let redactedMessage = sanitizer.sanitize(message)
    let previous = states[provider]
    let state = StoredProviderState(
      provider: provider,
      isEnabled: previous?.isEnabled ?? true,
      lastAttemptAt: now,
      lastSuccessfulAt: previous?.lastSuccessfulAt,
      refreshStatus: .failed,
      lastFailureMessage: redactedMessage
    )
    try? repository.saveProviderState(state)
    states[provider] = state
    attempts[provider] = [
      SourceAttempt(
        strategyID: "refresh",
        outcome: .failed(redactedMessage: redactedMessage)
      )
    ]
  }

  private func sanitize(_ attempts: [SourceAttempt]) -> [SourceAttempt] {
    attempts.map { attempt in
      let outcome: SourceAttempt.Outcome
      switch attempt.outcome {
      case .succeeded, .unavailable:
        outcome = attempt.outcome
      case .failed(let message):
        outcome = .failed(redactedMessage: sanitizer.sanitize(message))
      }
      return SourceAttempt(strategyID: attempt.strategyID, outcome: outcome)
    }
  }

  private func makeSnapshot(
    window: MonthWindow,
    enabledProviders: Set<ProviderID>,
    states: [ProviderID: StoredProviderState],
    attempts: [ProviderID: [SourceAttempt]],
    refreshedAt: Date
  ) -> RefreshSnapshot {
    let records = (try? repository.records(in: window)) ?? []
    let reconciled = reconciler.reconcile(records).included
    let freshness = Dictionary(
      uniqueKeysWithValues: enabledProviders.map {
        ($0, providerFreshness(for: states[$0], now: clock.now))
      }
    )
    let summary = aggregator.summarize(
      records: reconciled,
      enabledProviders: enabledProviders,
      window: window,
      providerFreshness: freshness
    )
    let allDataIsStale =
      !enabledProviders.isEmpty
      && enabledProviders.allSatisfy {
        if case .fresh = freshness[$0] {
          return false
        }
        return true
      }
    let pacing = pacingEngine.evaluate(
      spend: summary.total,
      budgets: (try? repository.budgets()) ?? [],
      now: clock.now,
      window: window,
      hasAnyData: !reconciled.isEmpty,
      allDataIsStale: allDataIsStale,
      isPartial: summary.isPartial
    )
    return RefreshSnapshot(
      summary: summary,
      pacing: pacing,
      attempts: attempts,
      refreshedAt: refreshedAt
    )
  }

  private func providerFreshness(
    for state: StoredProviderState?,
    now: Date
  ) -> Freshness {
    guard let state else {
      return .unavailable(message: "Provider has not refreshed")
    }
    if state.refreshStatus == .failed {
      return .unavailable(
        message: state.lastFailureMessage ?? "Provider refresh failed"
      )
    }
    guard let lastSuccessfulAt = state.lastSuccessfulAt else {
      return .unavailable(message: "Provider has not refreshed")
    }
    let age = max(0, now.timeIntervalSince(lastSuccessfulAt))
    return age > 30 * 60 ? .stale(age: age) : .fresh
  }

  private func fallbackSnapshot(at now: Date) -> RefreshSnapshot {
    let summary = MonthlySummary(
      total: .zero,
      actual: .zero,
      estimated: .zero,
      providers: [],
      isPartial: true
    )
    let pacing = pacingEngine.evaluate(
      spend: .zero,
      budgets: [],
      now: now,
      window: MonthWindow(start: now, end: now.addingTimeInterval(1)),
      hasAnyData: false,
      allDataIsStale: true,
      isPartial: true
    )
    return RefreshSnapshot(
      summary: summary,
      pacing: pacing,
      attempts: [:],
      refreshedAt: now
    )
  }
}

private enum AdapterOutcome: Sendable {
  case success(ProviderFetchResult)
  case failure(provider: ProviderID, message: String)
  case cancelled(provider: ProviderID)
}

private enum RefreshCoordinatorError: Error {
  case providerMismatch
}
