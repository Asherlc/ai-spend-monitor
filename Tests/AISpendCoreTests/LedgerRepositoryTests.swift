import Foundation
import SwiftData
import XCTest

@testable import AISpendCore

@MainActor
final class LedgerRepositoryTests: XCTestCase {
  func testReplaceStoresRecordsAndReplacesOnlyMatchingSourceInterval() throws {
    let repository = try makeRepository()
    let month = monthWindow()
    let original = try record(
      id: "original",
      amount: Decimal(string: "1.2300")!,
      sourceID: "anthropic.cost"
    )
    let otherSource = try record(
      id: "local",
      amount: 2,
      sourceID: "claude.local"
    )

    try repository.replace(
      records: [original],
      provider: .claude,
      sourceID: "anthropic.cost",
      interval: month
    )
    try repository.replace(
      records: [otherSource],
      provider: .claude,
      sourceID: "claude.local",
      interval: month
    )

    XCTAssertEqual(
      Set(try repository.records(in: month)),
      [otherSource, original]
    )

    let replacement = try record(
      id: "replacement",
      amount: Decimal(string: "3.4500")!,
      sourceID: "anthropic.cost"
    )
    try repository.replace(
      records: [replacement],
      provider: .claude,
      sourceID: "anthropic.cost",
      interval: month
    )

    XCTAssertEqual(
      Set(try repository.records(in: month)),
      [otherSource, replacement]
    )
  }

  func testInvalidReplacementPreservesPriorSuccessfulRecords() throws {
    let repository = try makeRepository()
    let month = monthWindow()
    let prior = try record(
      id: "prior",
      amount: 8,
      sourceID: "anthropic.cost"
    )
    try repository.replace(
      records: [prior],
      provider: .claude,
      sourceID: "anthropic.cost",
      interval: month
    )
    let valid = try record(
      id: "valid",
      amount: 4,
      sourceID: "anthropic.cost"
    )
    let wrongProvider = try record(
      id: "wrong-provider",
      provider: .openAI,
      amount: 9,
      sourceID: "anthropic.cost"
    )

    XCTAssertThrowsError(
      try repository.replace(
        records: [valid, wrongProvider],
        provider: .claude,
        sourceID: "anthropic.cost",
        interval: month
      )
    ) { error in
      XCTAssertEqual(error as? LedgerError, .invalidRecord)
    }
    XCTAssertEqual(try repository.records(in: month), [prior])
  }

  func testFailedSaveRollsBackPendingReplacementChanges() throws {
    let container = try makeContainer()
    let month = monthWindow()
    let prior = try record(
      id: "prior",
      amount: 8,
      sourceID: "anthropic.cost"
    )
    try SwiftDataLedgerRepository(modelContainer: container).replace(
      records: [prior],
      provider: .claude,
      sourceID: "anthropic.cost",
      interval: month
    )
    let repository = SwiftDataLedgerRepository(
      modelContainer: container,
      saveContext: { _ in throw TestSaveError.forced }
    )
    let incoming = try record(
      id: "replacement",
      amount: 4,
      sourceID: "anthropic.cost"
    )

    XCTAssertThrowsError(
      try repository.replace(
        records: [incoming],
        provider: .claude,
        sourceID: "anthropic.cost",
        interval: month
      )
    )
    XCTAssertEqual(try repository.records(in: month), [prior])
  }

  func testBatchProviderRefreshFailureAfterFirstSourceRollsBackEverySourceAndState()
    throws
  {
    let container = try makeContainer()
    let month = monthWindow()
    let seedingRepository = SwiftDataLedgerRepository(modelContainer: container)
    let priorActual = try record(
      id: "prior-actual",
      amount: 8,
      sourceID: "anthropic.cost"
    )
    let priorLocal = try record(
      id: "prior-local",
      amount: 2,
      sourceID: "claude.local"
    )
    let priorState = StoredProviderState(
      provider: .claude,
      isEnabled: true,
      lastAttemptAt: month.start,
      lastSuccessfulAt: month.start,
      refreshStatus: .success
    )
    try seedingRepository.replace(
      records: [priorActual],
      provider: .claude,
      sourceID: "anthropic.cost",
      interval: month
    )
    try seedingRepository.replace(
      records: [priorLocal],
      provider: .claude,
      sourceID: "claude.local",
      interval: month
    )
    try seedingRepository.saveProviderState(priorState)
    let repository = SwiftDataLedgerRepository(
      modelContainer: container,
      beforeStagingSource: { index, _ in
        if index == 1 { throw TestSaveError.forced }
      }
    )
    let replacementActual = try record(
      id: "replacement-actual",
      amount: 12,
      sourceID: "anthropic.cost"
    )
    let replacementLocal = try record(
      id: "replacement-local",
      amount: 5,
      sourceID: "claude.local"
    )
    let replacementState = StoredProviderState(
      provider: .claude,
      isEnabled: true,
      lastAttemptAt: month.start.addingTimeInterval(60),
      lastSuccessfulAt: month.start.addingTimeInterval(60),
      refreshStatus: .success
    )

    XCTAssertThrowsError(
      try repository.applyProviderRefresh(
        records: [replacementActual, replacementLocal],
        provider: .claude,
        refreshedSourceIDs: ["anthropic.cost", "claude.local"],
        interval: month,
        state: replacementState
      )
    )

    XCTAssertEqual(
      Set(try repository.records(in: month)),
      [priorActual, priorLocal]
    )
    XCTAssertEqual(try repository.providerStates()[.claude], priorState)
  }

  func testReplaceAcceptsSameRecordIDForMatchingSourceInterval() throws {
    let repository = try makeRepository()
    let month = monthWindow()
    let original = try record(
      id: "stable-id",
      amount: 1,
      sourceID: "anthropic.cost"
    )
    try repository.replace(
      records: [original],
      provider: .claude,
      sourceID: "anthropic.cost",
      interval: month
    )
    let replacement = try record(
      id: "stable-id",
      amount: 2,
      sourceID: "anthropic.cost"
    )

    try repository.replace(
      records: [replacement],
      provider: .claude,
      sourceID: "anthropic.cost",
      interval: month
    )

    XCTAssertEqual(try repository.records(in: month), [replacement])
  }

  func testReplaceRejectsRecordIDCollisionOutsideTargetScope() throws {
    let month = monthWindow()
    let cases: [(String, SpendRecord, ProviderID, String, MonthWindow)] = [
      (
        "source",
        try record(
          id: "collision",
          amount: 1,
          sourceID: "claude.local"
        ),
        .claude,
        "anthropic.cost",
        month
      ),
      (
        "provider",
        try record(
          id: "collision",
          provider: .openAI,
          amount: 1,
          sourceID: "anthropic.cost"
        ),
        .claude,
        "anthropic.cost",
        month
      ),
      (
        "month",
        try record(
          id: "collision",
          amount: 1,
          sourceID: "anthropic.cost",
          start: month.end
        ),
        .claude,
        "anthropic.cost",
        month
      ),
    ]

    for (scope, retained, provider, sourceID, interval) in cases {
      let repository = try makeRepository()
      let retainedWindow = MonthWindow(
        start: retained.intervalStart,
        end: retained.intervalEnd
      )
      try repository.replace(
        records: [retained],
        provider: retained.provider,
        sourceID: retained.sourceID,
        interval: retainedWindow
      )
      let incoming = try record(
        id: retained.id,
        provider: provider,
        amount: 2,
        sourceID: sourceID
      )

      XCTAssertThrowsError(
        try repository.replace(
          records: [incoming],
          provider: provider,
          sourceID: sourceID,
          interval: interval
        ),
        "Expected \(scope) collision to be rejected"
      ) { error in
        XCTAssertEqual(error as? LedgerError, .invalidRecord)
      }
      XCTAssertEqual(
        try repository.records(in: retainedWindow),
        [retained],
        "Expected \(scope) record to be retained"
      )
    }
  }

  func testMoneyIsStoredAsCanonicalBaseTenString() throws {
    let container = try makeContainer()
    let repository = SwiftDataLedgerRepository(modelContainer: container)
    let month = monthWindow()
    let stored = try record(
      id: "canonical",
      amount: Decimal(string: "123.4500")!,
      sourceID: "anthropic.cost"
    )
    try repository.replace(
      records: [stored],
      provider: .claude,
      sourceID: "anthropic.cost",
      interval: month
    )

    let inspectionContext = ModelContext(container)
    let entity = try XCTUnwrap(
      inspectionContext.fetch(FetchDescriptor<SpendRecordEntity>()).first
    )
    XCTAssertEqual(entity.amountString, "123.45")
  }

  func testCorruptDecimalSuffixIsRejectedInsteadOfPartiallyParsed() throws {
    let container = try makeContainer()
    let context = ModelContext(container)
    let start = monthWindow().start
    context.insert(
      SpendRecordEntity(
        recordID: "corrupt",
        providerRawValue: ProviderID.claude.rawValue,
        accountFingerprint: "account",
        model: "model",
        intervalStart: start,
        intervalEnd: start.addingTimeInterval(86_400),
        amountString: "123junk",
        currency: "USD",
        qualityRawValue: SpendQuality.actual.rawValue,
        sourceID: "anthropic.cost",
        observationID: "observation",
        fetchedAt: start,
        estimateData: nil
      )
    )
    try context.save()
    let repository = SwiftDataLedgerRepository(modelContainer: container)

    XCTAssertThrowsError(try repository.records(in: monthWindow())) { error in
      XCTAssertEqual(error as? LedgerError, .corruptedData)
    }
  }

  func testDuplicateBudgetLimitIsRejectedEvenWhenExistingBudgetIsDisabled() throws {
    let repository = try makeRepository()
    let now = Date(timeIntervalSince1970: 1_704_067_200)
    var existing = try repository.addBudget(limit: Money(100), now: now)
    existing.isEnabled = false
    try repository.updateBudget(existing)

    XCTAssertThrowsError(
      try repository.addBudget(
        limit: Money(Decimal(string: "100.00")!),
        now: now
      )
    ) { error in
      XCTAssertEqual(error as? LedgerError, .duplicateBudget)
    }
    XCTAssertEqual(try repository.budgets(), [existing])
  }

  func testUpdatingBudgetToEnabledOrDisabledDuplicateLimitIsRejected() throws {
    let repository = try makeRepository()
    let now = Date(timeIntervalSince1970: 1_704_067_200)
    let first = try repository.addBudget(limit: Money(100), now: now)
    var second = try repository.addBudget(
      limit: Money(200),
      now: now.addingTimeInterval(1)
    )

    for isEnabled in [true, false] {
      second.limit = first.limit
      second.isEnabled = isEnabled
      XCTAssertThrowsError(try repository.updateBudget(second)) { error in
        XCTAssertEqual(error as? LedgerError, .duplicateBudget)
      }
    }
  }

  func testDisablingProviderRetainsStoredRecords() throws {
    let repository = try makeRepository()
    let month = monthWindow()
    let stored = try record(
      id: "stored",
      amount: 7,
      sourceID: "anthropic.cost"
    )
    try repository.replace(
      records: [stored],
      provider: .claude,
      sourceID: "anthropic.cost",
      interval: month
    )

    let state = StoredProviderState(
      provider: .claude,
      isEnabled: false,
      lastAttemptAt: Date(timeIntervalSince1970: 1_704_067_300),
      lastSuccessfulAt: Date(timeIntervalSince1970: 1_704_067_200),
      refreshStatus: .success,
      lastFailureMessage: nil
    )
    try repository.saveProviderState(state)

    XCTAssertEqual(try repository.providerStates(), [.claude: state])
    XCTAssertEqual(try repository.records(in: month), [stored])
  }

  func testProviderStateRoundTripsPartialRefreshStatus() throws {
    let repository = try makeRepository()
    let state = StoredProviderState(
      provider: .fireworks,
      isEnabled: true,
      lastAttemptAt: Date(timeIntervalSince1970: 200),
      lastSuccessfulAt: Date(timeIntervalSince1970: 200),
      refreshStatus: .partial,
      lastFailureMessage: "Only authenticated-user spend is available."
    )

    try repository.saveProviderState(state)

    XCTAssertEqual(try repository.providerStates()[.fireworks], state)
  }

  func testFailedRefreshStateRetainsPriorSuccessfulRecords() throws {
    let repository = try makeRepository()
    let month = monthWindow()
    let stored = try record(
      id: "stored",
      amount: 7,
      sourceID: "anthropic.cost"
    )
    try repository.replace(
      records: [stored],
      provider: .claude,
      sourceID: "anthropic.cost",
      interval: month
    )

    let failure = StoredProviderState(
      provider: .claude,
      isEnabled: true,
      lastAttemptAt: Date(timeIntervalSince1970: 1_704_067_300),
      lastSuccessfulAt: Date(timeIntervalSince1970: 1_704_067_200),
      refreshStatus: .failed,
      lastFailureMessage: "Authentication unavailable"
    )
    try repository.saveProviderState(failure)

    XCTAssertEqual(try repository.providerStates(), [.claude: failure])
    XCTAssertEqual(try repository.records(in: month), [stored])
  }

  func testFailedProviderStateSaveRollsBackPriorState() throws {
    let container = try makeContainer()
    let prior = StoredProviderState(
      provider: .claude,
      isEnabled: true,
      refreshStatus: .success
    )
    try SwiftDataLedgerRepository(modelContainer: container)
      .saveProviderState(prior)
    let repository = failingRepository(container: container)
    let replacement = StoredProviderState(
      provider: .claude,
      isEnabled: false,
      refreshStatus: .failed,
      lastFailureMessage: "Unavailable"
    )

    XCTAssertThrowsError(try repository.saveProviderState(replacement))
    XCTAssertEqual(try repository.providerStates(), [.claude: prior])
  }

  func testFailedBudgetAddRollsBackInsertedBudget() throws {
    let container = try makeContainer()
    let repository = failingRepository(container: container)

    XCTAssertThrowsError(
      try repository.addBudget(
        limit: Money(100),
        now: Date(timeIntervalSince1970: 1_704_067_200)
      )
    )
    XCTAssertEqual(try repository.budgets(), [])
  }

  func testFailedBudgetUpdateRollsBackPriorBudget() throws {
    let container = try makeContainer()
    let seedingRepository = SwiftDataLedgerRepository(
      modelContainer: container
    )
    let prior = try seedingRepository.addBudget(
      limit: Money(100),
      now: Date(timeIntervalSince1970: 1_704_067_200)
    )
    var replacement = prior
    replacement.limit = Money(200)
    replacement.isEnabled = false
    let repository = failingRepository(container: container)

    XCTAssertThrowsError(try repository.updateBudget(replacement))
    XCTAssertEqual(try repository.budgets(), [prior])
  }

  func testFailedBudgetRemovalRollsBackBudgetAndAlertState() throws {
    let container = try makeContainer()
    let seedingRepository = SwiftDataLedgerRepository(
      modelContainer: container
    )
    let prior = try seedingRepository.addBudget(
      limit: Money(100),
      now: Date(timeIntervalSince1970: 1_704_067_200)
    )
    let priorAlert = StoredBudgetAlertState(
      budgetID: prior.id,
      lastPacingState: .offPace
    )
    try seedingRepository.saveAlertState(priorAlert)
    let repository = failingRepository(container: container)

    XCTAssertThrowsError(try repository.removeBudget(id: prior.id))
    XCTAssertEqual(try repository.budgets(), [prior])
    XCTAssertEqual(try repository.alertState(for: prior.id), priorAlert)
  }

  func testFailedAlertStateSaveRollsBackPriorState() throws {
    let container = try makeContainer()
    let seedingRepository = SwiftDataLedgerRepository(
      modelContainer: container
    )
    let budget = try seedingRepository.addBudget(
      limit: Money(100),
      now: Date(timeIntervalSince1970: 1_704_067_200)
    )
    let prior = StoredBudgetAlertState(
      budgetID: budget.id,
      lastPacingState: .onPace
    )
    try seedingRepository.saveAlertState(prior)
    let replacement = StoredBudgetAlertState(
      budgetID: budget.id,
      lastPacingState: .offPace,
      lastImmediateAlertAt: Date(timeIntervalSince1970: 1_704_067_300)
    )
    let repository = failingRepository(container: container)

    XCTAssertThrowsError(try repository.saveAlertState(replacement))
    XCTAssertEqual(try repository.alertState(for: budget.id), prior)
  }

  func testRemovedBudgetCannotRecreateOrphanAlertState() throws {
    let container = try makeContainer()
    let repository = SwiftDataLedgerRepository(modelContainer: container)
    let budget = try repository.addBudget(
      limit: Money(100),
      now: Date(timeIntervalSince1970: 1_704_067_200)
    )
    let alert = StoredBudgetAlertState(
      budgetID: budget.id,
      lastPacingState: .offPace
    )
    try repository.saveAlertState(alert)
    try repository.removeBudget(id: budget.id)

    let inspectionContext = ModelContext(container)
    XCTAssertEqual(
      try inspectionContext.fetchCount(FetchDescriptor<BudgetEntity>()),
      0
    )
    XCTAssertEqual(
      try inspectionContext.fetchCount(
        FetchDescriptor<BudgetAlertStateEntity>()
      ),
      0
    )
    XCTAssertThrowsError(try repository.saveAlertState(alert)) { error in
      XCTAssertEqual(error as? LedgerError, .budgetNotFound)
    }
    XCTAssertEqual(
      try inspectionContext.fetchCount(
        FetchDescriptor<BudgetAlertStateEntity>()
      ),
      0
    )
  }

  func testProviderFailureMessageIsSanitizedBeforePersistence() throws {
    let container = try makeContainer()
    let repository = SwiftDataLedgerRepository(modelContainer: container)
    let secrets = [
      "secret-bearer",
      "session-cookie",
      "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.signature",
      "sk-ant-api03-secretvalue",
      "admin-secret-value",
      "person@example.com",
      "acct_123456789",
      "json-bearer-secret",
      "json-cookie-secret",
      "generic-api-secret",
      "generic-admin-secret",
      "generic-account-123",
      "equals-bearer-secret",
      "equals-cookie-secret",
    ]
    let rawDiagnostic = """
      Authorization: Bearer secret-bearer
      Cookie: session=session-cookie
      jwt=\(secrets[2])
      apiKey=\(secrets[3])
      admin_key=\(secrets[4])
      email=\(secrets[5])
      account_id=\(secrets[6])
      {"Authorization":"Bearer \(secrets[7])"}
      {"Cookie":"session=\(secrets[8])"}
      {"api_key":"\(secrets[9])"}
      {"adminKey":"\(secrets[10])"}
      {"account_id":"\(secrets[11])"}
      Authorization=Bearer \(secrets[12])
      Cookie=session=\(secrets[13])
      """
    let state = StoredProviderState(
      provider: .claude,
      isEnabled: true,
      refreshStatus: .failed,
      lastFailureMessage: rawDiagnostic
    )

    try repository.saveProviderState(state)

    let inspectionContext = ModelContext(container)
    let entity = try XCTUnwrap(
      inspectionContext.fetch(FetchDescriptor<ProviderStateEntity>()).first
    )
    let persisted = try XCTUnwrap(entity.lastFailureMessage)
    let roundTripped = try XCTUnwrap(
      repository.providerStates()[.claude]?.lastFailureMessage
    )
    XCTAssertEqual(roundTripped, persisted)
    XCTAssertTrue(persisted.contains("[REDACTED]"))
    for secret in secrets {
      XCTAssertFalse(persisted.contains(secret))
    }
  }

  func testBudgetCRUDAndAlertStateRoundTrip() throws {
    let repository = try makeRepository()
    let now = Date(timeIntervalSince1970: 1_704_067_200)
    var budget = try repository.addBudget(
      limit: Money(Decimal(string: "123.4500")!),
      now: now
    )
    XCTAssertEqual(try repository.budgets(), [budget])

    budget.limit = Money(150)
    budget.isEnabled = false
    try repository.updateBudget(budget)
    XCTAssertEqual(try repository.budgets(), [budget])

    XCTAssertEqual(
      try repository.alertState(for: budget.id),
      StoredBudgetAlertState(budgetID: budget.id)
    )
    let alertState = StoredBudgetAlertState(
      budgetID: budget.id,
      lastPacingState: .offPace,
      lastImmediateAlertAt: now,
      lastReminderAt: now.addingTimeInterval(86_400)
    )
    try repository.saveAlertState(alertState)
    XCTAssertEqual(try repository.alertState(for: budget.id), alertState)

    try repository.removeBudget(id: budget.id)
    XCTAssertEqual(try repository.budgets(), [])
  }

  private func makeRepository() throws -> SwiftDataLedgerRepository {
    try SwiftDataLedgerRepository(modelContainer: makeContainer())
  }

  private func failingRepository(
    container: ModelContainer
  ) -> SwiftDataLedgerRepository {
    SwiftDataLedgerRepository(
      modelContainer: container,
      saveContext: { _ in throw TestSaveError.forced }
    )
  }

  private func makeContainer() throws -> ModelContainer {
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
    return try ModelContainer(
      for: schema,
      configurations: [configuration]
    )
  }

  private func monthWindow() -> MonthWindow {
    let start = Date(timeIntervalSince1970: 1_704_067_200)
    return MonthWindow(
      start: start,
      end: start.addingTimeInterval(31 * 86_400)
    )
  }

  private func record(
    id: String,
    provider: ProviderID = .claude,
    amount: Decimal,
    sourceID: String,
    start: Date = Date(timeIntervalSince1970: 1_704_067_200)
  ) throws -> SpendRecord {
    return try SpendRecord(
      id: id,
      provider: provider,
      accountFingerprint: "account",
      model: "model",
      intervalStart: start,
      intervalEnd: start.addingTimeInterval(86_400),
      amount: Money(amount),
      quality: .actual,
      sourceID: sourceID,
      observationID: "observation-\(id)",
      fetchedAt: start.addingTimeInterval(60),
      estimate: EstimateMetadata(
        inputTokens: 1,
        cachedInputTokens: 2,
        outputTokens: 3,
        catalogVersion: "2026-07-27"
      )
    )
  }

  private enum TestSaveError: Error {
    case forced
  }
}
