import Foundation

public enum RefreshReason: Hashable, Sendable {
  case launch
  case periodic
  case popover
  case manual
  case providerEnabled(ProviderID)
}

public enum CurrentMonthDataAvailability: String, Hashable, Sendable {
  case available
  case unavailable
}

public struct RefreshSnapshot: Sendable {
  public let summary: MonthlySummary
  public let pacing: PacingResult
  public let attempts: [ProviderID: [SourceAttempt]]
  public let allDataIsStale: Bool
  public let refreshedAt: Date
  public let evaluatedAt: Date
  public let monthWindow: MonthWindow
  public let providerStates: [ProviderID: StoredProviderState]
  public let dataAvailability: CurrentMonthDataAvailability
  public let providerAvailability: [ProviderID: CurrentMonthDataAvailability]

  public init(
    summary: MonthlySummary,
    pacing: PacingResult,
    attempts: [ProviderID: [SourceAttempt]],
    allDataIsStale: Bool,
    refreshedAt: Date,
    evaluatedAt: Date? = nil,
    monthWindow: MonthWindow? = nil,
    providerStates: [ProviderID: StoredProviderState] = [:],
    dataAvailability: CurrentMonthDataAvailability? = nil,
    providerAvailability: [ProviderID: CurrentMonthDataAvailability] = [:]
  ) {
    self.summary = summary
    self.pacing = pacing
    self.attempts = attempts
    self.allDataIsStale = allDataIsStale
    self.refreshedAt = refreshedAt
    self.evaluatedAt = evaluatedAt ?? refreshedAt
    self.monthWindow =
      monthWindow
      ?? (try? MonthWindow.current(containing: refreshedAt, calendar: .current))
      ?? MonthWindow(start: refreshedAt, end: refreshedAt.addingTimeInterval(1))
    self.providerStates = providerStates
    let resolvedAvailability =
      dataAvailability
      ?? (!summary.providers.isEmpty ? .available : .unavailable)
    self.dataAvailability = resolvedAvailability
    if providerAvailability.isEmpty {
      self.providerAvailability = Dictionary(
        uniqueKeysWithValues: summary.providers.map { ($0.id, .available) }
      )
    } else {
      self.providerAvailability = providerAvailability
    }
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
    let initialStates: [ProviderID: StoredProviderState]
    do {
      initialStates = try repository.providerStates()
    } catch {
      return repositoryFailureSnapshot(
        at: now,
        message: "Unable to read provider states"
      )
    }

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
          let sanitizedAttempts = sanitize(result.attempts)
          let failureMessage = firstProblemMessage(in: sanitizedAttempts)
          let state = StoredProviderState(
            provider: provider,
            isEnabled: previous?.isEnabled ?? true,
            lastAttemptAt: now,
            lastSuccessfulAt: result.refreshedSourceIDs.isEmpty
              ? previous?.lastSuccessfulAt
              : now,
            refreshStatus: failureMessage == nil ? .success : .failed,
            lastFailureMessage: failureMessage
          )
          try repository.saveProviderState(state)
          states[provider] = state
          attempts[provider] = sanitizedAttempts
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
    let cancellation = ProviderTimeoutCancellation()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let race = ProviderTimeoutRace(continuation: continuation)
        cancellation.install(race)
        race.start(timeout: timeout, operation: operation)
      }
    } onCancel: {
      cancellation.cancel()
    }
  }

  private func persist(
    result: ProviderFetchResult,
    in window: MonthWindow
  ) throws {
    guard result.records.allSatisfy({ $0.provider == result.provider }) else {
      throw RefreshCoordinatorError.providerMismatch
    }
    let recordSourceIDs = Set(result.records.map(\.sourceID))
    guard recordSourceIDs.isSubset(of: result.refreshedSourceIDs) else {
      throw RefreshCoordinatorError.unrefreshedRecordSource
    }
    let recordsBySource = Dictionary(grouping: result.records, by: \.sourceID)
    for sourceID in result.refreshedSourceIDs {
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
      case .succeeded:
        outcome = attempt.outcome
      case .unavailable(let reason):
        outcome = .unavailable(reason: sanitizer.sanitize(reason))
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
    attempts initialAttempts: [ProviderID: [SourceAttempt]],
    refreshedAt: Date
  ) -> RefreshSnapshot {
    var attempts = initialAttempts
    var spendRecordsReadFailed = false
    var ancillaryReadFailed = false
    let records: [SpendRecord]
    do {
      records = try repository.records(in: window)
    } catch {
      records = []
      spendRecordsReadFailed = true
      appendRepositoryFailure(
        "Unable to read cached spend",
        enabledProviders: enabledProviders,
        attempts: &attempts
      )
    }
    let enabledRecords = records.filter {
      enabledProviders.contains($0.provider)
    }
    let reconciled = reconciler.reconcile(enabledRecords).included
    let freshness = Dictionary(
      uniqueKeysWithValues: enabledProviders.map {
        ($0, providerFreshness(for: states[$0], now: clock.now))
      }
    )
    let aggregated = aggregator.summarize(
      records: reconciled,
      enabledProviders: enabledProviders,
      window: window,
      providerFreshness: freshness
    )
    let allDataIsStale =
      !enabledProviders.isEmpty
      && enabledProviders.allSatisfy {
        guard let lastSuccessfulAt = states[$0]?.lastSuccessfulAt else {
          return true
        }
        return clock.now.timeIntervalSince(lastSuccessfulAt) > 30 * 60
      }
    let budgets: [BudgetDefinition]
    do {
      budgets = try repository.budgets()
    } catch {
      budgets = []
      ancillaryReadFailed = true
      appendRepositoryFailure(
        "Unable to read budgets",
        enabledProviders: enabledProviders,
        attempts: &attempts
      )
    }
    let summary = MonthlySummary(
      total: aggregated.total,
      actual: aggregated.actual,
      estimated: aggregated.estimated,
      providers: aggregated.providers,
      isPartial: aggregated.isPartial || spendRecordsReadFailed || ancillaryReadFailed
    )
    let providerAvailability = Dictionary(
      uniqueKeysWithValues: enabledProviders.map { provider in
        let hasRecords = reconciled.contains { $0.provider == provider }
        let hasCurrentWindowSuccess =
          states[provider]?.lastSuccessfulAt.map(window.contains) ?? false
        let availability: CurrentMonthDataAvailability =
          !spendRecordsReadFailed && (hasRecords || hasCurrentWindowSuccess)
          ? .available : .unavailable
        return (provider, availability)
      }
    )
    let dataAvailability: CurrentMonthDataAvailability =
      providerAvailability.values.contains(.available)
      ? .available : .unavailable
    let pacing = pacingEngine.evaluate(
      spend: summary.total,
      budgets: budgets,
      now: clock.now,
      window: window,
      hasAnyData: dataAvailability == .available,
      allDataIsStale: allDataIsStale,
      isPartial: summary.isPartial
    )
    return RefreshSnapshot(
      summary: summary,
      pacing: pacing,
      attempts: attempts,
      allDataIsStale: allDataIsStale,
      refreshedAt: refreshedAt,
      evaluatedAt: clock.now,
      monthWindow: window,
      providerStates: states,
      dataAvailability: dataAvailability,
      providerAvailability: providerAvailability
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
    let window =
      (try? MonthWindow.current(containing: now, calendar: calendar))
      ?? MonthWindow(start: now, end: now.addingTimeInterval(1))
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
      window: window,
      hasAnyData: false,
      allDataIsStale: true,
      isPartial: true
    )
    return RefreshSnapshot(
      summary: summary,
      pacing: pacing,
      attempts: [:],
      allDataIsStale: true,
      refreshedAt: now,
      evaluatedAt: now,
      monthWindow: window,
      providerStates: [:],
      dataAvailability: .unavailable,
      providerAvailability: [:]
    )
  }

  private func repositoryFailureSnapshot(
    at now: Date,
    message: String
  ) -> RefreshSnapshot {
    let redactedMessage = sanitizer.sanitize(message)
    let providers = Set(adapters.map(\.provider))
    let states = Dictionary(
      uniqueKeysWithValues: providers.map {
        (
          $0,
          StoredProviderState(
            provider: $0,
            isEnabled: true,
            lastAttemptAt: now,
            refreshStatus: .failed,
            lastFailureMessage: redactedMessage
          )
        )
      }
    )
    let attempts = Dictionary(
      uniqueKeysWithValues: providers.map {
        (
          $0,
          [
            SourceAttempt(
              strategyID: "repository",
              outcome: .failed(redactedMessage: redactedMessage)
            )
          ]
        )
      }
    )
    let fallback = fallbackSnapshot(at: now)
    return RefreshSnapshot(
      summary: fallback.summary,
      pacing: fallback.pacing,
      attempts: attempts,
      allDataIsStale: true,
      refreshedAt: now,
      evaluatedAt: now,
      monthWindow: fallback.monthWindow,
      providerStates: states,
      dataAvailability: .unavailable,
      providerAvailability: Dictionary(
        uniqueKeysWithValues: providers.map { ($0, .unavailable) }
      )
    )
  }

  private func firstProblemMessage(
    in attempts: [SourceAttempt]
  ) -> String? {
    for attempt in attempts {
      switch attempt.outcome {
      case .succeeded:
        continue
      case .unavailable(let reason):
        return reason
      case .failed(let message):
        return message
      }
    }
    return nil
  }

  private func appendRepositoryFailure(
    _ message: String,
    enabledProviders: Set<ProviderID>,
    attempts: inout [ProviderID: [SourceAttempt]]
  ) {
    let providers =
      enabledProviders.isEmpty
      ? Set(adapters.map(\.provider))
      : enabledProviders
    for provider in providers {
      attempts[provider, default: []].append(
        SourceAttempt(
          strategyID: "repository",
          outcome: .failed(redactedMessage: sanitizer.sanitize(message))
        )
      )
    }
  }
}

private enum AdapterOutcome: Sendable {
  case success(ProviderFetchResult)
  case failure(provider: ProviderID, message: String)
  case cancelled(provider: ProviderID)
}

private enum RefreshCoordinatorError: Error {
  case providerMismatch
  case unrefreshedRecordSource
}

private final class ProviderTimeoutCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var race: ProviderTimeoutRace?
  private var isCancelled = false

  func install(_ race: ProviderTimeoutRace) {
    lock.lock()
    if isCancelled {
      lock.unlock()
      race.cancel()
      return
    }
    self.race = race
    lock.unlock()
  }

  func cancel() {
    lock.lock()
    isCancelled = true
    let race = race
    lock.unlock()
    race?.cancel()
  }
}

private final class ProviderTimeoutRace: @unchecked Sendable {
  private enum Winner {
    case operation
    case timeout
  }

  private let lock = NSLock()
  private var continuation: CheckedContinuation<ProviderFetchResult, any Error>?
  private var operationTask: Task<Void, Never>?
  private var timeoutTask: Task<Void, Never>?

  init(
    continuation: CheckedContinuation<ProviderFetchResult, any Error>
  ) {
    self.continuation = continuation
  }

  func start(
    timeout: TimeInterval,
    operation: ProviderOperation
  ) {
    let operationTask = Task.detached {
      do {
        let value = try await operation()
        self.resolve(.success(value), winner: .operation)
      } catch {
        self.resolve(.failure(error), winner: .operation)
      }
    }
    let timeoutTask = Task.detached {
      do {
        try await Task.sleep(for: .seconds(timeout))
        self.resolve(
          .failure(ProviderTimeoutError.timedOut),
          winner: .timeout
        )
      } catch is CancellationError {
        return
      } catch {
        self.resolve(.failure(error), winner: .timeout)
      }
    }

    lock.lock()
    self.operationTask = operationTask
    self.timeoutTask = timeoutTask
    let didFinish = continuation == nil
    lock.unlock()

    if didFinish {
      operationTask.cancel()
      timeoutTask.cancel()
    }
  }

  func cancel() {
    resolve(.failure(CancellationError()), winner: nil)
  }

  private func resolve(
    _ result: Result<ProviderFetchResult, any Error>,
    winner: Winner?
  ) {
    lock.lock()
    guard let continuation else {
      lock.unlock()
      return
    }
    self.continuation = nil
    let operationTask = operationTask
    let timeoutTask = timeoutTask
    lock.unlock()

    switch winner {
    case .operation:
      timeoutTask?.cancel()
    case .timeout:
      operationTask?.cancel()
    case nil:
      operationTask?.cancel()
      timeoutTask?.cancel()
    }
    continuation.resume(with: result)
  }
}
