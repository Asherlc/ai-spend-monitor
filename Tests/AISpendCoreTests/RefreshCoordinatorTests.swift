import AISpendCore
import Foundation
import SwiftData
import XCTest

@MainActor
final class RefreshCoordinatorTests: XCTestCase {
  func testDisabledAdaptersAreNeverFetched() async throws {
    let repository = try makeRepository()
    try repository.saveProviderState(
      StoredProviderState(provider: .claude, isEnabled: false)
    )
    try repository.saveProviderState(
      StoredProviderState(provider: .openAI, isEnabled: true)
    )
    let disabled = AdapterSpy(provider: .claude, result: .success([]))
    let enabled = AdapterSpy(provider: .openAI, result: .success([]))
    let coordinator = makeCoordinator(
      adapters: [disabled, enabled],
      repository: repository
    )

    _ = await coordinator.refresh(reason: .launch)

    let disabledFetchCount = await disabled.fetchCount
    let enabledFetchCount = await enabled.fetchCount
    XCTAssertEqual(disabledFetchCount, 0)
    XCTAssertEqual(enabledFetchCount, 1)
  }

  func testEnabledAdaptersRunConcurrently() async throws {
    let repository = try makeRepository()
    try enable([.claude, .openAI], in: repository)
    let gate = Rendezvous(participantCount: 2)
    let claude = AdapterSpy(provider: .claude) { window in
      await gate.arrive()
      return Self.fetchResult(provider: .claude, records: [], window: window)
    }
    let openAI = AdapterSpy(provider: .openAI) { window in
      await gate.arrive()
      return Self.fetchResult(provider: .openAI, records: [], window: window)
    }
    let coordinator = makeCoordinator(
      adapters: [claude, openAI],
      repository: repository
    )

    _ = await coordinator.refresh(reason: .manual)

    let arrivalCount = await gate.arrivalCount
    XCTAssertEqual(arrivalCount, 2)
  }

  func testFailurePreservesFailedProviderCacheAndPersistsSuccessfulSibling() async throws {
    let repository = try makeRepository()
    try enable([.claude, .openAI], in: repository)
    let cachedClaude = try record(
      id: "cached-claude",
      provider: .claude,
      amount: 7,
      sourceID: "claude-cost"
    )
    try repository.replace(
      records: [cachedClaude],
      provider: .claude,
      sourceID: cachedClaude.sourceID,
      interval: month
    )
    let freshOpenAI = try record(
      id: "fresh-openai",
      provider: .openAI,
      amount: 11,
      sourceID: "openai-cost"
    )
    let claude = AdapterSpy(
      provider: .claude,
      result: .failure(
        TestFailure.message("authorization=sk-secretsecret account_id=acct_private")
      )
    )
    let openAI = AdapterSpy(
      provider: .openAI,
      result: .success([freshOpenAI])
    )
    let coordinator = makeCoordinator(
      adapters: [claude, openAI],
      repository: repository
    )

    let snapshot = await coordinator.refresh(reason: .periodic)

    XCTAssertEqual(
      Set(try repository.records(in: month).map(\.id)),
      [
        "cached-claude", "fresh-openai",
      ])
    XCTAssertEqual(snapshot.summary.total, Money(18))
    XCTAssertTrue(snapshot.summary.isPartial)
    guard case .failed(let message) = snapshot.attempts[.claude]?.first?.outcome else {
      return XCTFail("Expected a failed Claude attempt")
    }
    XCTAssertFalse(message.contains("sk-secretsecret"))
    XCTAssertFalse(message.contains("acct_private"))
    XCTAssertTrue(message.contains("[REDACTED]"))

    let claudeState = try XCTUnwrap(repository.providerStates()[.claude])
    XCTAssertEqual(claudeState.refreshStatus, .failed)
    XCTAssertEqual(claudeState.lastSuccessfulAt, nil)
    XCTAssertEqual(claudeState.lastFailureMessage, message)
    let openAIState = try XCTUnwrap(repository.providerStates()[.openAI])
    XCTAssertEqual(openAIState.refreshStatus, .success)
    XCTAssertEqual(openAIState.lastSuccessfulAt, now)
  }

  func testEveryEnabledAdapterUsesTwentySecondTimeout() async throws {
    let repository = try makeRepository()
    try enable([.claude, .openAI], in: repository)
    let timeout = TimeoutSpy()
    let claude = AdapterSpy(provider: .claude, result: .success([]))
    let openAI = AdapterSpy(provider: .openAI, result: .success([]))
    let coordinator = makeCoordinator(
      adapters: [claude, openAI],
      repository: repository,
      withTimeout: { duration, operation in
        try await timeout.run(duration, operation)
      }
    )

    let snapshot = await coordinator.refresh(reason: .providerEnabled(.claude))

    let receivedTimeouts = await timeout.receivedTimeouts
    XCTAssertEqual(receivedTimeouts.sorted(), [20, 20])
    let fetchCounts = await [claude.fetchCount, openAI.fetchCount]
    XCTAssertEqual(fetchCounts, [1, 1])
    let outcomes = snapshot.attempts.values.compactMap { $0.first?.outcome }
    XCTAssertEqual(outcomes.count, 2)
    XCTAssertTrue(
      outcomes.allSatisfy {
        $0 == .failed(redactedMessage: "Provider refresh timed out")
      }
    )
  }

  func testRecentPopoverAttemptReturnsCachedSnapshotWithoutFetching() async throws {
    let repository = try makeRepository()
    try repository.saveProviderState(
      StoredProviderState(
        provider: .claude,
        isEnabled: true,
        lastAttemptAt: now.addingTimeInterval(-59),
        lastSuccessfulAt: now.addingTimeInterval(-59),
        refreshStatus: .success
      )
    )
    let adapter = AdapterSpy(provider: .claude, result: .success([]))
    let coordinator = makeCoordinator(
      adapters: [adapter],
      repository: repository
    )

    let snapshot = await coordinator.refresh(reason: .popover)

    let fetchCount = await adapter.fetchCount
    XCTAssertEqual(fetchCount, 0)
    XCTAssertEqual(snapshot.refreshedAt, now.addingTimeInterval(-59))
  }

  func testFreshnessGuardOnlyAppliesToPopoverReason() async throws {
    let reasons: [RefreshReason] = [
      .launch, .periodic, .manual, .providerEnabled(.claude),
    ]

    for reason in reasons {
      let repository = try makeRepository()
      try repository.saveProviderState(
        StoredProviderState(
          provider: .claude,
          isEnabled: true,
          lastAttemptAt: now.addingTimeInterval(-1),
          lastSuccessfulAt: now.addingTimeInterval(-1),
          refreshStatus: .success
        )
      )
      let adapter = AdapterSpy(provider: .claude, result: .success([]))
      let coordinator = makeCoordinator(
        adapters: [adapter],
        repository: repository
      )

      _ = await coordinator.refresh(reason: reason)

      let fetchCount = await adapter.fetchCount
      XCTAssertEqual(fetchCount, 1, "Reason: \(reason)")
    }
  }

  func testCancellingRefreshCancelsInFlightAdapters() async throws {
    let repository = try makeRepository()
    try enable([.claude], in: repository)
    let probe = CancellationProbe()
    let adapter = AdapterSpy(provider: .claude) { _ in
      try await probe.suspendUntilCancelled()
    }
    let coordinator = makeCoordinator(
      adapters: [adapter],
      repository: repository
    )
    let refresh = Task {
      await coordinator.refresh(reason: .manual)
    }
    await probe.waitUntilStarted()

    refresh.cancel()
    _ = await refresh.value

    let observedCancellation = await probe.observedCancellation
    XCTAssertTrue(observedCancellation)
  }

  func testSuccessfulEmptySourceClearsItsCachedInterval() async throws {
    let repository = try makeRepository()
    try enable([.openAI], in: repository)
    let cached = try record(
      id: "cached-openai",
      provider: .openAI,
      amount: 9,
      sourceID: "openai-cost"
    )
    try repository.replace(
      records: [cached],
      provider: .openAI,
      sourceID: cached.sourceID,
      interval: month
    )
    let fetchedAt = now
    let adapter = AdapterSpy(provider: .openAI) { _ in
      ProviderFetchResult(
        provider: .openAI,
        records: [],
        attempts: [
          SourceAttempt(
            strategyID: "openai-actual",
            outcome: .succeeded(recordCount: 0)
          )
        ],
        refreshedSourceIDs: ["openai-cost"],
        fetchedAt: fetchedAt
      )
    }
    let coordinator = makeCoordinator(
      adapters: [adapter],
      repository: repository
    )

    _ = await coordinator.refresh(reason: .manual)

    XCTAssertTrue(try repository.records(in: month).isEmpty)
  }

  func testPersistsRawSourceRecordsAndReconcilesOnlyDerivedSnapshot() async throws {
    let repository = try makeRepository()
    try enable([.claude], in: repository)
    let actual = try record(
      id: "actual",
      provider: .claude,
      amount: 4,
      sourceID: "claude-actual"
    )
    let estimate = try record(
      id: "estimate",
      provider: .claude,
      amount: 3,
      sourceID: "claude-local",
      quality: .estimated,
      observationID: "different-observation"
    )
    let fetchedAt = now
    let adapter = AdapterSpy(provider: .claude) { _ in
      ProviderFetchResult(
        provider: .claude,
        records: [actual, estimate],
        attempts: [
          .init(strategyID: "actual", outcome: .succeeded(recordCount: 1)),
          .init(strategyID: "local", outcome: .succeeded(recordCount: 1)),
        ],
        refreshedSourceIDs: ["claude-actual", "claude-local"],
        fetchedAt: fetchedAt
      )
    }
    let coordinator = makeCoordinator(
      adapters: [adapter],
      repository: repository
    )

    let snapshot = await coordinator.refresh(reason: .manual)

    XCTAssertEqual(Set(try repository.records(in: month).map(\.id)), ["actual", "estimate"])
    XCTAssertEqual(snapshot.summary.total, Money(4))
  }

  func testMixedAttemptsRemainPartialAndSanitizeUnavailableMessage() async throws {
    let repository = try makeRepository()
    try enable([.claude], in: repository)
    let estimate = try record(
      id: "estimate",
      provider: .claude,
      amount: 3,
      sourceID: "claude-local",
      quality: .estimated
    )
    let fetchedAt = now
    let adapter = AdapterSpy(provider: .claude) { _ in
      ProviderFetchResult(
        provider: .claude,
        records: [estimate],
        attempts: [
          .init(
            strategyID: "actual",
            outcome: .unavailable(reason: "account_id=acct_private unavailable")
          ),
          .init(strategyID: "local", outcome: .succeeded(recordCount: 1)),
        ],
        refreshedSourceIDs: ["claude-local"],
        fetchedAt: fetchedAt
      )
    }
    let coordinator = makeCoordinator(
      adapters: [adapter],
      repository: repository
    )

    let snapshot = await coordinator.refresh(reason: .manual)

    XCTAssertTrue(snapshot.summary.isPartial)
    let state = try XCTUnwrap(repository.providerStates()[.claude])
    XCTAssertEqual(state.refreshStatus, .failed)
    XCTAssertEqual(state.lastSuccessfulAt, now)
    guard case .unavailable(let reason) = snapshot.attempts[.claude]?.first?.outcome else {
      return XCTFail("Expected unavailable source attempt")
    }
    XCTAssertFalse(reason.contains("acct_private"))
    XCTAssertTrue(reason.contains("[REDACTED]"))
  }

  func testRecentSuccessfulCacheWithLatestFailureIsPartialButNotAllStale() async throws {
    let repository = try makeRepository()
    try repository.saveProviderState(
      StoredProviderState(
        provider: .claude,
        isEnabled: true,
        lastSuccessfulAt: now.addingTimeInterval(-60),
        refreshStatus: .success
      )
    )
    let cached = try record(
      id: "cached",
      provider: .claude,
      amount: 5,
      sourceID: "claude-local"
    )
    try repository.replace(
      records: [cached],
      provider: .claude,
      sourceID: cached.sourceID,
      interval: month
    )
    let coordinator = makeCoordinator(
      adapters: [
        AdapterSpy(
          provider: .claude,
          result: .failure(.message("temporary failure"))
        )
      ],
      repository: repository
    )

    let snapshot = await coordinator.refresh(reason: .periodic)

    XCTAssertTrue(snapshot.summary.isPartial)
    XCTAssertFalse(snapshot.allDataIsStale)
  }

  func testOldSuccessfulCacheWithLatestFailureIsAllStale() async throws {
    let repository = try makeRepository()
    try repository.saveProviderState(
      StoredProviderState(
        provider: .claude,
        isEnabled: true,
        lastSuccessfulAt: now.addingTimeInterval(-1_801),
        refreshStatus: .success
      )
    )
    let cached = try record(
      id: "cached",
      provider: .claude,
      amount: 5,
      sourceID: "claude-local"
    )
    try repository.replace(
      records: [cached],
      provider: .claude,
      sourceID: cached.sourceID,
      interval: month
    )
    let coordinator = makeCoordinator(
      adapters: [
        AdapterSpy(
          provider: .claude,
          result: .failure(.message("temporary failure"))
        )
      ],
      repository: repository
    )

    let snapshot = await coordinator.refresh(reason: .periodic)

    XCTAssertTrue(snapshot.summary.isPartial)
    XCTAssertTrue(snapshot.allDataIsStale)
  }

  func testDisabledOnlyCacheLeavesPacingWithoutData() async throws {
    let repository = try makeRepository()
    try repository.saveProviderState(
      StoredProviderState(provider: .claude, isEnabled: false)
    )
    let cached = try record(
      id: "disabled-cache",
      provider: .claude,
      amount: 5,
      sourceID: "claude-local"
    )
    try repository.replace(
      records: [cached],
      provider: .claude,
      sourceID: cached.sourceID,
      interval: month
    )
    let budget = try repository.addBudget(limit: Money(100), now: now)
    let coordinator = makeCoordinator(adapters: [], repository: repository)

    let snapshot = await coordinator.refresh(reason: .manual)

    XCTAssertEqual(snapshot.summary.total, .zero)
    XCTAssertEqual(snapshot.pacing.budgets.first?.id, budget.id)
    XCTAssertEqual(snapshot.pacing.budgets.first?.state, .unknown)
  }

  func testProductionTimeoutReturnsBeforeNonCooperativeAdapterFinishes() async throws {
    let repository = try makeRepository()
    try enable([.openAI], in: repository)
    let fresh = try record(
      id: "late",
      provider: .openAI,
      amount: 12,
      sourceID: "openai-cost"
    )
    let adapter = NonCooperativeAdapter(
      provider: .openAI,
      result: Self.fetchResult(
        provider: .openAI,
        records: [fresh],
        window: month
      ),
      delay: 0.15
    )
    let coordinator = makeCoordinator(
      adapters: [adapter],
      repository: repository,
      timeout: 0.01
    )
    let started = ContinuousClock.now

    let snapshot = await coordinator.refresh(reason: .manual)

    let elapsed = started.duration(to: .now)
    XCTAssertLessThan(elapsed, .milliseconds(100))
    XCTAssertTrue(snapshot.summary.isPartial)
    XCTAssertTrue(try repository.records(in: month).isEmpty)
    await adapter.waitUntilFinished()
    XCTAssertTrue(try repository.records(in: month).isEmpty)
  }

  func testProviderStateReadFailureReturnsPartialDiagnostic() async throws {
    let base = try makeRepository()
    let repository = ReadFailingRepository(base: base, failingRead: .providerStates)
    let coordinator = makeCoordinator(
      adapters: [AdapterSpy(provider: .claude, result: .success([]))],
      repository: repository
    )

    let snapshot = await coordinator.refresh(reason: .launch)

    XCTAssertTrue(snapshot.summary.isPartial)
    guard case .failed(let message) = snapshot.attempts[.claude]?.first?.outcome else {
      return XCTFail("Expected repository read failure diagnostic")
    }
    XCTAssertTrue(message.contains("Unable to read provider states"))
  }

  func testBudgetReadFailureMarksSnapshotPartialAndAddsDiagnostic() async throws {
    let base = try makeRepository()
    try base.saveProviderState(
      StoredProviderState(
        provider: .claude,
        isEnabled: true,
        lastSuccessfulAt: now,
        refreshStatus: .success
      )
    )
    let repository = ReadFailingRepository(base: base, failingRead: .budgets)
    let coordinator = makeCoordinator(
      adapters: [AdapterSpy(provider: .claude, result: .success([]))],
      repository: repository
    )

    let snapshot = await coordinator.refresh(reason: .launch)

    XCTAssertTrue(snapshot.summary.isPartial)
    let messages: [String] = snapshot.attempts[.claude, default: []].compactMap {
      guard case .failed(let message) = $0.outcome else {
        return nil
      }
      return message
    }
    XCTAssertTrue(messages.contains("Unable to read budgets"))
  }

  func testCachedSpendReadFailureMarksSnapshotPartialAndAddsDiagnostic() async throws {
    let base = try makeRepository()
    try base.saveProviderState(
      StoredProviderState(
        provider: .claude,
        isEnabled: true,
        lastSuccessfulAt: now,
        refreshStatus: .success
      )
    )
    let repository = ReadFailingRepository(base: base, failingRead: .records)
    let coordinator = makeCoordinator(
      adapters: [AdapterSpy(provider: .claude, result: .success([]))],
      repository: repository
    )

    let snapshot = await coordinator.refresh(reason: .launch)

    XCTAssertTrue(snapshot.summary.isPartial)
    let messages: [String] = snapshot.attempts[.claude, default: []].compactMap {
      guard case .failed(let message) = $0.outcome else {
        return nil
      }
      return message
    }
    XCTAssertTrue(messages.contains("Unable to read cached spend"))
  }

  private let now = Date(timeIntervalSince1970: 1_704_153_600)

  private var month: MonthWindow {
    MonthWindow(
      start: Date(timeIntervalSince1970: 1_704_067_200),
      end: Date(timeIntervalSince1970: 1_706_745_600)
    )
  }

  private func makeCoordinator(
    adapters: [any ProviderAdapter],
    repository: any LedgerRepository,
    timeout: TimeInterval = 20,
    withTimeout: @escaping ProviderTimeout = RefreshCoordinator.withTimeout
  ) -> RefreshCoordinator {
    RefreshCoordinator(
      adapters: adapters,
      repository: repository,
      clock: FixedClock(now: now),
      calendar: utcCalendar,
      timeout: timeout,
      withTimeout: withTimeout
    )
  }

  private func enable(
    _ providers: [ProviderID],
    in repository: any LedgerRepository
  ) throws {
    for provider in providers {
      try repository.saveProviderState(
        StoredProviderState(provider: provider, isEnabled: true)
      )
    }
  }

  private func makeRepository() throws -> SwiftDataLedgerRepository {
    let schema = Schema([
      SpendRecordEntity.self,
      ProviderStateEntity.self,
      BudgetEntity.self,
      BudgetAlertStateEntity.self,
    ])
    let configuration = ModelConfiguration(
      schema: schema,
      isStoredInMemoryOnly: true
    )
    let container = try ModelContainer(
      for: schema,
      configurations: [configuration]
    )
    return SwiftDataLedgerRepository(modelContainer: container)
  }

  private func record(
    id: String,
    provider: ProviderID,
    amount: Decimal,
    sourceID: String,
    quality: SpendQuality = .actual,
    observationID: String? = nil
  ) throws -> SpendRecord {
    try SpendRecord(
      id: id,
      provider: provider,
      accountFingerprint: "account",
      model: "model",
      intervalStart: month.start,
      intervalEnd: month.start.addingTimeInterval(86_400),
      amount: Money(amount),
      quality: quality,
      sourceID: sourceID,
      observationID: observationID ?? "observation-\(id)",
      fetchedAt: now,
      estimate: nil
    )
  }

  private var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }

  nonisolated fileprivate static func fetchResult(
    provider: ProviderID,
    records: [SpendRecord],
    window _: MonthWindow,
    fetchedAt: Date = Date(timeIntervalSince1970: 1_704_153_600)
  ) -> ProviderFetchResult {
    ProviderFetchResult(
      provider: provider,
      records: records,
      attempts: [
        SourceAttempt(
          strategyID: "\(provider.rawValue)-source",
          outcome: .succeeded(recordCount: records.count)
        )
      ],
      refreshedSourceIDs: Set(records.map(\.sourceID)),
      fetchedAt: fetchedAt
    )
  }
}

private struct FixedClock: AISpendCore.Clock {
  let now: Date
}

private actor AdapterSpy: ProviderAdapter {
  nonisolated let provider: ProviderID
  private let implementation: @Sendable (MonthWindow) async throws -> ProviderFetchResult
  private(set) var fetchCount = 0

  init(
    provider: ProviderID,
    implementation:
      @escaping @Sendable (MonthWindow) async throws -> ProviderFetchResult
  ) {
    self.provider = provider
    self.implementation = implementation
  }

  init(
    provider: ProviderID,
    result: Result<[SpendRecord], TestFailure>
  ) {
    self.init(provider: provider) { window in
      switch result {
      case .success(let records):
        return RefreshCoordinatorTests.fetchResult(
          provider: provider,
          records: records,
          window: window
        )
      case .failure(let error):
        throw error
      }
    }
  }

  func fetch(window: MonthWindow) async throws -> ProviderFetchResult {
    fetchCount += 1
    return try await implementation(window)
  }
}

private actor Rendezvous {
  private let participantCount: Int
  private var arrivals = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(participantCount: Int) {
    self.participantCount = participantCount
  }

  var arrivalCount: Int {
    arrivals
  }

  func arrive() async {
    arrivals += 1
    if arrivals == participantCount {
      let currentWaiters = waiters
      waiters.removeAll()
      for waiter in currentWaiters {
        waiter.resume()
      }
      return
    }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }
}

private actor TimeoutSpy {
  private(set) var receivedTimeouts: [TimeInterval] = []

  func run(
    _ timeout: TimeInterval,
    _ operation: ProviderOperation
  ) async throws -> ProviderFetchResult {
    receivedTimeouts.append(timeout)
    _ = try await operation()
    throw ProviderTimeoutError.timedOut
  }
}

private actor CancellationProbe {
  private var isStarted = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var continuation: CheckedContinuation<ProviderFetchResult, any Error>?
  private(set) var observedCancellation = false

  func waitUntilStarted() async {
    if isStarted {
      return
    }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func suspendUntilCancelled() async throws -> ProviderFetchResult {
    isStarted = true
    let currentWaiters = startWaiters
    startWaiters.removeAll()
    for waiter in currentWaiters {
      waiter.resume()
    }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        self.continuation = continuation
      }
    } onCancel: {
      Task {
        await self.cancel()
      }
    }
  }

  private func cancel() {
    observedCancellation = true
    continuation?.resume(throwing: CancellationError())
    continuation = nil
  }
}

private actor NonCooperativeAdapter: ProviderAdapter {
  nonisolated let provider: ProviderID
  private let result: ProviderFetchResult
  private let delay: TimeInterval
  private var isFinished = false
  private var finishWaiters: [CheckedContinuation<Void, Never>] = []

  init(
    provider: ProviderID,
    result: ProviderFetchResult,
    delay: TimeInterval
  ) {
    self.provider = provider
    self.result = result
    self.delay = delay
  }

  func fetch(window _: MonthWindow) async throws -> ProviderFetchResult {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
        continuation.resume()
      }
    }
    isFinished = true
    let waiters = finishWaiters
    finishWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    return result
  }

  func waitUntilFinished() async {
    if isFinished {
      return
    }
    await withCheckedContinuation { continuation in
      finishWaiters.append(continuation)
    }
  }
}

@MainActor
private final class ReadFailingRepository: LedgerRepository {
  enum FailingRead: Equatable {
    case records
    case providerStates
    case budgets
  }

  private let base: any LedgerRepository
  private let failingRead: FailingRead

  init(base: any LedgerRepository, failingRead: FailingRead) {
    self.base = base
    self.failingRead = failingRead
  }

  func records(in window: MonthWindow) throws -> [SpendRecord] {
    if failingRead == .records {
      throw TestFailure.message("database unavailable")
    }
    return try base.records(in: window)
  }

  func replace(
    records: [SpendRecord],
    provider: ProviderID,
    sourceID: String,
    interval: MonthWindow
  ) throws {
    try base.replace(
      records: records,
      provider: provider,
      sourceID: sourceID,
      interval: interval
    )
  }

  func providerStates() throws -> [ProviderID: StoredProviderState] {
    if failingRead == .providerStates {
      throw TestFailure.message("database unavailable")
    }
    return try base.providerStates()
  }

  func saveProviderState(_ state: StoredProviderState) throws {
    try base.saveProviderState(state)
  }

  func budgets() throws -> [BudgetDefinition] {
    if failingRead == .budgets {
      throw TestFailure.message("database unavailable")
    }
    return try base.budgets()
  }

  func addBudget(limit: Money, now: Date) throws -> BudgetDefinition {
    try base.addBudget(limit: limit, now: now)
  }

  func updateBudget(_ budget: BudgetDefinition) throws {
    try base.updateBudget(budget)
  }

  func removeBudget(id: UUID) throws {
    try base.removeBudget(id: id)
  }

  func alertState(for budgetID: UUID) throws -> StoredBudgetAlertState {
    try base.alertState(for: budgetID)
  }

  func saveAlertState(_ state: StoredBudgetAlertState) throws {
    try base.saveAlertState(state)
  }
}

private enum TestFailure: Error, Sendable {
  case message(String)
}
