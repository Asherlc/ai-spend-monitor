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
    withTimeout: @escaping ProviderTimeout = RefreshCoordinator.withTimeout
  ) -> RefreshCoordinator {
    RefreshCoordinator(
      adapters: adapters,
      repository: repository,
      clock: FixedClock(now: now),
      calendar: utcCalendar,
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
    sourceID: String
  ) throws -> SpendRecord {
    try SpendRecord(
      id: id,
      provider: provider,
      accountFingerprint: "account",
      model: "model",
      intervalStart: month.start,
      intervalEnd: month.start.addingTimeInterval(86_400),
      amount: Money(amount),
      quality: .actual,
      sourceID: sourceID,
      observationID: "observation-\(id)",
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

private enum TestFailure: Error, Sendable {
  case message(String)
}
