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
  public let evaluationCalendar: Calendar
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
    evaluationCalendar: Calendar? = nil,
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
    self.evaluationCalendar = evaluationCalendar ?? .current
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
  private let calendarProvider: @Sendable () -> Calendar
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
    calendar: Calendar? = nil,
    calendarProvider: @escaping @Sendable () -> Calendar = {
      .autoupdatingCurrent
    },
    timeout: TimeInterval = 45,
    withTimeout: @escaping ProviderTimeout = RefreshCoordinator.withTimeout,
    sanitizer: DiagnosticSanitizer = DiagnosticSanitizer()
  ) {
    self.adapters = adapters
    self.repository = repository
    self.reconciler = reconciler
    self.aggregator = aggregator
    self.pacingEngine = pacingEngine
    self.clock = clock
    if let calendar {
      self.calendarProvider = { calendar }
    } else {
      self.calendarProvider = calendarProvider
    }
    self.timeout = timeout
    runWithTimeout = withTimeout
    self.sanitizer = sanitizer
  }

  public func refresh(reason: RefreshReason) async -> RefreshSnapshot {
    lastRefreshReason = reason
    let now = clock.now
    let calendar = calendarProvider()
    guard
      let window = try? MonthWindow.current(
        containing: now,
        calendar: calendar
      )
    else {
      return fallbackSnapshot(at: now, calendar: calendar)
    }
    let initialStates: [ProviderID: StoredProviderState]
    do {
      initialStates = try repository.providerStates()
    } catch {
      return repositoryFailureSnapshot(
        at: now,
        calendar: calendar,
        message: "Unable to read provider states"
      )
    }

    if reason == .popover,
      let lastAttemptAt = initialStates.values.compactMap(\.lastAttemptAt).max(),
      now.timeIntervalSince(lastAttemptAt) < 60
    {
      if let lastSnapshot,
        lastSnapshot.monthWindow == window,
        sameEvaluationCalendar(
          lastSnapshot.evaluationCalendar,
          calendar
        )
      {
        return lastSnapshot
      }
      if lastSnapshot == nil {
        return makeCachedSnapshot(
          window: window,
          calendar: calendar,
          now: now,
          states: initialStates
        )
      }
    }

    var activeNow = now
    var activeCalendar = calendar
    var activeWindow = window
    var states = initialStates
    var outcomes: [AdapterOutcome] = []
    var remainingCalendarRetries = 1
    while true {
      states = (try? repository.providerStates()) ?? states
      let enabledProviders = Set(
        states.values.filter(\.isEnabled).map(\.provider)
      )
      outcomes = await fetchOutcomes(
        window: activeWindow,
        enabledProviders: enabledProviders
      )

      if Task.isCancelled {
        return (try? cachedSnapshot())
          ?? fallbackSnapshot(at: clock.now, calendar: calendarProvider())
      }

      let latestNow = clock.now
      let latestCalendar = calendarProvider()
      guard
        let latestWindow = try? MonthWindow.current(
          containing: latestNow,
          calendar: latestCalendar
        )
      else {
        return fallbackSnapshot(at: latestNow, calendar: latestCalendar)
      }
      let contextChanged =
        latestWindow != activeWindow
        || !sameEvaluationCalendar(activeCalendar, latestCalendar)
      guard contextChanged else {
        activeNow = latestNow
        break
      }

      activeNow = latestNow
      activeCalendar = latestCalendar
      activeWindow = latestWindow
      if remainingCalendarRetries > 0 {
        remainingCalendarRetries -= 1
        continue
      }

      states = (try? repository.providerStates()) ?? states
      let currentEnabledProviders = Set(
        states.values.filter(\.isEnabled).map(\.provider)
      )
      let snapshot = makeSnapshot(
        window: activeWindow,
        calendar: activeCalendar,
        enabledProviders: currentEnabledProviders,
        states: states,
        attempts: [:],
        refreshedAt: activeNow,
        evaluatedAt: activeNow
      )
      lastSnapshot = snapshot
      return snapshot
    }

    var attempts: [ProviderID: [SourceAttempt]] = [:]
    for outcome in outcomes {
      switch outcome {
      case .success(let result):
        let provider = result.provider
        do {
          let currentStates = try repository.providerStates()
          guard
            let current = currentStates[provider],
            current.isEnabled
          else {
            if let current = currentStates[provider] {
              states[provider] = current
            }
            continue
          }
          let sanitizedAttempts = sanitize(result.attempts)
          let failureMessage = firstProblemMessage(
            in: sanitizedAttempts,
            refreshedAnySource: !result.refreshedSourceIDs.isEmpty
          )
          let coverageMessage: String?
          let refreshStatus: ProviderRefreshStatus
          switch result.coverage {
          case .complete:
            coverageMessage = failureMessage
            refreshStatus = failureMessage == nil ? .success : .failed
          case .partial(let message):
            coverageMessage = message
            refreshStatus = .partial
          }
          let state = StoredProviderState(
            provider: provider,
            isEnabled: current.isEnabled,
            lastAttemptAt: activeNow,
            lastSuccessfulAt: result.refreshedSourceIDs.isEmpty
              ? current.lastSuccessfulAt
              : activeNow,
            refreshStatus: refreshStatus,
            lastFailureMessage: coverageMessage
          )
          try persist(
            result: result,
            state: state,
            in: activeWindow,
            refreshGeneration: activeNow
          )
          states[provider] = state
          attempts[provider] = sanitizedAttempts
        } catch {
          recordFailure(
            provider: provider,
            message: String(describing: error),
            now: activeNow,
            states: &states,
            attempts: &attempts
          )
        }
      case .failure(let provider, let message):
        recordFailure(
          provider: provider,
          message: message,
          now: activeNow,
          states: &states,
          attempts: &attempts
        )
      case .cancelled:
        break
      }
    }

    if let currentStates = try? repository.providerStates() {
      states = currentStates
    }
    let currentEnabledProviders = Set(
      states.values.filter(\.isEnabled).map(\.provider)
    )
    let snapshot = makeSnapshot(
      window: activeWindow,
      calendar: activeCalendar,
      enabledProviders: currentEnabledProviders,
      states: states,
      attempts: attempts,
      refreshedAt: activeNow,
      evaluatedAt: activeNow
    )
    lastSnapshot = snapshot
    return snapshot
  }

  public func cachedSnapshot() throws -> RefreshSnapshot {
    let now = clock.now
    let calendar = calendarProvider()
    let window = try MonthWindow.current(
      containing: now,
      calendar: calendar
    )
    if let lastSnapshot,
      lastSnapshot.monthWindow == window,
      sameEvaluationCalendar(lastSnapshot.evaluationCalendar, calendar)
    {
      return lastSnapshot
    }

    let states = try repository.providerStates()
    return makeCachedSnapshot(
      window: window,
      calendar: calendar,
      now: now,
      states: states
    )
  }

  private func makeCachedSnapshot(
    window: MonthWindow,
    calendar: Calendar,
    now: Date,
    states: [ProviderID: StoredProviderState]
  ) -> RefreshSnapshot {
    let enabledProviders = Set(
      states.values.filter(\.isEnabled).map(\.provider)
    )
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
      calendar: calendar,
      enabledProviders: enabledProviders,
      states: states,
      attempts: attempts,
      refreshedAt: refreshedAt,
      evaluatedAt: now
    )
  }

  private func fetchOutcomes(
    window: MonthWindow,
    enabledProviders: Set<ProviderID>
  ) async -> [AdapterOutcome] {
    let enabledAdapters = adapters.filter {
      enabledProviders.contains($0.provider)
    }
    let timeout = timeout
    let runWithTimeout = runWithTimeout
    return await withTaskGroup(
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
    state: StoredProviderState,
    in window: MonthWindow,
    refreshGeneration: Date
  ) throws {
    guard result.records.allSatisfy({ $0.provider == result.provider }) else {
      throw RefreshCoordinatorError.providerMismatch
    }
    let recordSourceIDs = Set(result.records.map(\.sourceID))
    guard recordSourceIDs.isSubset(of: result.refreshedSourceIDs) else {
      throw RefreshCoordinatorError.unrefreshedRecordSource
    }
    let records = try result.records.map {
      try SpendRecord(
        id: $0.id,
        provider: $0.provider,
        accountFingerprint: $0.accountFingerprint,
        model: $0.model,
        intervalStart: $0.intervalStart,
        intervalEnd: $0.intervalEnd,
        amount: $0.amount,
        quality: $0.quality,
        sourceID: $0.sourceID,
        observationID: $0.observationID,
        fetchedAt: refreshGeneration,
        estimate: $0.estimate
      )
    }
    try repository.applyProviderRefresh(
      records: records,
      provider: result.provider,
      refreshedSourceIDs: result.refreshedSourceIDs,
      sourceAuthority: result.sourceAuthority,
      interval: window,
      state: state
    )
  }

  private func recordFailure(
    provider: ProviderID,
    message: String,
    now: Date,
    states: inout [ProviderID: StoredProviderState],
    attempts: inout [ProviderID: [SourceAttempt]]
  ) {
    let redactedMessage = sanitizer.sanitize(message)
    let currentStates = try? repository.providerStates()
    guard
      let current = currentStates?[provider],
      current.isEnabled
    else {
      if let current = currentStates?[provider] {
        states[provider] = current
      }
      return
    }
    let state = StoredProviderState(
      provider: provider,
      isEnabled: current.isEnabled,
      lastAttemptAt: now,
      lastSuccessfulAt: current.lastSuccessfulAt,
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
    calendar: Calendar,
    enabledProviders: Set<ProviderID>,
    states: [ProviderID: StoredProviderState],
    attempts initialAttempts: [ProviderID: [SourceAttempt]],
    refreshedAt: Date,
    evaluatedAt: Date
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
        ($0, providerFreshness(for: states[$0], now: evaluatedAt))
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
        return evaluatedAt.timeIntervalSince(lastSuccessfulAt) > 30 * 60
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
      now: evaluatedAt,
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
      evaluatedAt: evaluatedAt,
      monthWindow: window,
      evaluationCalendar: calendar,
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
    if age > 30 * 60 {
      return .stale(age: age)
    }
    if state.refreshStatus == .partial {
      return .partial(
        age: age,
        message: state.lastFailureMessage ?? "Provider coverage is partial"
      )
    }
    return .fresh
  }

  private func fallbackSnapshot(
    at now: Date,
    calendar: Calendar? = nil
  ) -> RefreshSnapshot {
    let calendar = calendar ?? calendarProvider()
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
      evaluationCalendar: calendar,
      providerStates: [:],
      dataAvailability: .unavailable,
      providerAvailability: [:]
    )
  }

  private func repositoryFailureSnapshot(
    at now: Date,
    calendar: Calendar,
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
    let fallback = fallbackSnapshot(at: now, calendar: calendar)
    return RefreshSnapshot(
      summary: fallback.summary,
      pacing: fallback.pacing,
      attempts: attempts,
      allDataIsStale: true,
      refreshedAt: now,
      evaluatedAt: now,
      monthWindow: fallback.monthWindow,
      evaluationCalendar: fallback.evaluationCalendar,
      providerStates: states,
      dataAvailability: .unavailable,
      providerAvailability: Dictionary(
        uniqueKeysWithValues: providers.map { ($0, .unavailable) }
      )
    )
  }

  private func firstProblemMessage(
    in attempts: [SourceAttempt],
    refreshedAnySource: Bool
  ) -> String? {
    var firstUnavailableReason: String?
    for attempt in attempts {
      switch attempt.outcome {
      case .succeeded:
        continue
      case .unavailable(let reason):
        if !refreshedAnySource && firstUnavailableReason == nil {
          firstUnavailableReason = reason
        }
      case .failed(let message):
        return message
      }
    }
    return firstUnavailableReason
  }

  private func sameEvaluationCalendar(
    _ lhs: Calendar,
    _ rhs: Calendar
  ) -> Bool {
    lhs.identifier == rhs.identifier
      && lhs.timeZone == rhs.timeZone
      && lhs.locale?.identifier == rhs.locale?.identifier
      && lhs.firstWeekday == rhs.firstWeekday
      && lhs.minimumDaysInFirstWeek == rhs.minimumDaysInFirstWeek
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
