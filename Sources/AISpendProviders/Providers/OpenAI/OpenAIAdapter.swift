import AISpendCore
import Foundation

public struct OpenAIAdapter: ProviderAdapter {
  public let provider = ProviderID.openAI

  private let credential: @Sendable () throws -> Secret?
  private let actual: @Sendable (MonthWindow, Secret) async throws -> [OpenAICostRow]
  private let local: @Sendable (MonthWindow, Date) throws -> LocalLogScanResult
  private let fingerprinter: AccountFingerprinter
  private let localIdentity: Secret
  private let now: @Sendable () -> Date
  private let redactor: Redactor

  init(
    credential: @escaping @Sendable () throws -> Secret?,
    actual: @escaping @Sendable (MonthWindow, Secret) async throws -> [OpenAICostRow],
    local: @escaping @Sendable (MonthWindow, Date) throws -> LocalLogScanResult,
    fingerprinter: AccountFingerprinter = .production,
    localIdentity: Secret = Secret(UUID().uuidString),
    now: @escaping @Sendable () -> Date,
    redactor: Redactor = Redactor()
  ) {
    self.credential = credential
    self.actual = actual
    self.local = local
    self.fingerprinter = fingerprinter
    self.localIdentity = localIdentity
    self.now = now
    self.redactor = redactor
  }

  public init(
    credentialHost: CredentialHost = CredentialHost(),
    scanner: CodexLogScanner,
    httpClient: HTTPClient = HTTPClient(),
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    let client = OpenAICostClient(httpClient: httpClient)
    self.init(
      credential: { try Self.productionCredential(from: credentialHost) },
      actual: { window, credential in
        try await client.fetch(window: window, credential: credential)
      },
      local: scanner.scan,
      fingerprinter: .production,
      localIdentity: Secret(FileManager.default.homeDirectoryForCurrentUser.path),
      now: now
    )
  }

  public func fetch(window: MonthWindow) async throws -> ProviderFetchResult {
    try Task.checkCancellation()
    let fetchedAt = now()
    var records: [SpendRecord] = []
    var attempts: [SourceAttempt] = []
    var refreshedSourceIDs = Set<String>()
    var resolvedCredential: Secret?
    var modelLessCoverage: [(Date, Date)] = []
    var coverage = ProviderDataCoverage.complete
    let accountFingerprint: String
    do {
      resolvedCredential = try credential()
      accountFingerprint = try fingerprint(for: resolvedCredential)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      accountFingerprint = try fingerprint(for: nil)
      attempts.append(
        .init(strategyID: "openai-actual", outcome: .failed(redactedMessage: message(for: error)))
      )
    }

    if attempts.isEmpty {
      do {
        if let resolvedCredential {
          try Task.checkCancellation()
          let rows = try await actual(window, resolvedCredential)
          let actualRecords = try rows.enumerated().map { index, row in
            let observationID = stableIdentifier([
              "openai-cost", accountFingerprint,
              String(row.start.timeIntervalSince1970), String(row.end.timeIntervalSince1970),
              String(index),
            ])
            return try SpendRecord(
              id: observationID,
              provider: .openAI,
              accountFingerprint: accountFingerprint,
              model: row.model ?? "unknown",
              intervalStart: row.start,
              intervalEnd: row.end,
              amount: Money(row.amount),
              quality: .actual,
              sourceID: "openai-organization-costs",
              observationID: observationID,
              fetchedAt: fetchedAt,
              estimate: nil
            )
          }
          modelLessCoverage = rows.filter { $0.model == nil }.map { ($0.start, $0.end) }
          records.append(contentsOf: actualRecords)
          refreshedSourceIDs.insert("openai-organization-costs")
          attempts.append(
            .init(strategyID: "openai-actual", outcome: .succeeded(recordCount: rows.count)))
        } else {
          attempts.append(
            .init(
              strategyID: "openai-actual",
              outcome: .unavailable(reason: "No OpenAI organization admin credential.")
            )
          )
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        attempts.append(
          .init(strategyID: "openai-actual", outcome: .failed(redactedMessage: message(for: error)))
        )
      }
    }

    do {
      try Task.checkCancellation()
      let result = try local(window, fetchedAt)
      let uncovered = result.records.filter { estimate in
        !modelLessCoverage.contains { start, end in
          estimate.intervalStart < end && start < estimate.intervalEnd
        }
      }
      records.append(
        contentsOf: try uncovered.map {
          try Self.reaccount($0, accountFingerprint: accountFingerprint)
        }
      )
      if !result.diagnostics.isEmpty {
        coverage = .partial(message: "Some Codex local spend is unavailable.")
      }
      refreshedSourceIDs.insert("openai-local-logs")
      attempts.append(
        .init(
          strategyID: "openai-local-estimate",
          outcome: .succeeded(recordCount: uncovered.count)
        )
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      attempts.append(
        .init(
          strategyID: "openai-local-estimate",
          outcome: .failed(redactedMessage: redactor.redact(error.localizedDescription))
        )
      )
    }
    return ProviderFetchResult(
      provider: provider,
      records: records,
      attempts: attempts,
      refreshedSourceIDs: refreshedSourceIDs,
      fetchedAt: fetchedAt,
      coverage: coverage
    )
  }

  static func productionCredential(from host: CredentialHost) throws -> Secret? {
    try host.environmentSecret(named: "OPENAI_ADMIN_KEY")
  }

  private func message(for error: Error) -> String {
    if case ProviderClientError.httpStatus(let status) = error, status == 401 || status == 403 {
      return "Authorization failed (HTTP \(status))."
    }
    return redactor.redact(error.localizedDescription)
  }

  private func fingerprint(for credential: Secret?) throws -> String {
    try fingerprinter.fingerprint(
      identity: credential ?? localIdentity,
      namespace: "openai-account"
    )
  }

  private static func reaccount(
    _ record: SpendRecord,
    accountFingerprint: String
  ) throws -> SpendRecord {
    try SpendRecord(
      id: stableIdentifier([accountFingerprint, record.id]),
      provider: record.provider,
      accountFingerprint: accountFingerprint,
      model: record.model,
      intervalStart: record.intervalStart,
      intervalEnd: record.intervalEnd,
      amount: record.amount,
      quality: record.quality,
      sourceID: record.sourceID,
      observationID: stableIdentifier([accountFingerprint, record.observationID]),
      fetchedAt: record.fetchedAt,
      estimate: record.estimate
    )
  }
}
