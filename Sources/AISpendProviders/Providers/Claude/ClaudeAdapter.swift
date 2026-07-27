import AISpendCore
import Foundation

public struct ClaudeAdapter: ProviderAdapter {
  public let provider = ProviderID.claude

  private let credential: @Sendable () throws -> ClaudeCredential?
  private let actual: @Sendable (MonthWindow, ClaudeCredential) async throws -> [ClaudeCostRow]
  private let local: @Sendable (MonthWindow, Date) throws -> LocalLogScanResult
  private let fingerprinter: AccountFingerprinter
  private let localIdentity: Secret
  private let now: @Sendable () -> Date
  private let redactor: Redactor

  init(
    credential: @escaping @Sendable () throws -> ClaudeCredential?,
    actual: @escaping @Sendable (MonthWindow, ClaudeCredential) async throws -> [ClaudeCostRow],
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
    scanner: ClaudeLogScanner,
    httpClient: HTTPClient = HTTPClient(),
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    let client = ClaudeCostClient(httpClient: httpClient)
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
    var resolvedCredential: ClaudeCredential?
    var modelLessCoverage: [(Date, Date)] = []
    let accountFingerprint: String

    do {
      resolvedCredential = try credential()
      accountFingerprint = fingerprint(for: resolvedCredential)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      accountFingerprint = fingerprint(for: nil)
      attempts.append(
        .init(strategyID: "claude-actual", outcome: .failed(redactedMessage: message(for: error)))
      )
    }

    if attempts.isEmpty {
      do {
        if let resolvedCredential {
          try Task.checkCancellation()
          let rows = try await actual(window, resolvedCredential)
          let actualRecords = try rows.enumerated().map { index, row in
            let observationID = stableIdentifier([
              "claude-cost", accountFingerprint,
              String(row.start.timeIntervalSince1970), String(row.end.timeIntervalSince1970),
              String(index),
            ])
            return try SpendRecord(
              id: observationID,
              provider: .claude,
              accountFingerprint: accountFingerprint,
              model: row.model ?? "unknown",
              intervalStart: row.start,
              intervalEnd: row.end,
              amount: Money(row.amount),
              quality: .actual,
              sourceID: "claude-cost-report",
              observationID: observationID,
              fetchedAt: fetchedAt,
              estimate: nil
            )
          }
          modelLessCoverage = rows.filter { $0.model == nil }.map { ($0.start, $0.end) }
          records.append(contentsOf: actualRecords)
          refreshedSourceIDs.insert("claude-cost-report")
          attempts.append(
            .init(strategyID: "claude-actual", outcome: .succeeded(recordCount: rows.count)))
        } else {
          attempts.append(
            .init(
              strategyID: "claude-actual",
              outcome: .unavailable(reason: "No Claude organization admin credential.")
            )
          )
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        attempts.append(
          .init(strategyID: "claude-actual", outcome: .failed(redactedMessage: message(for: error)))
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
      refreshedSourceIDs.insert("claude-local-logs")
      attempts.append(
        .init(
          strategyID: "claude-local-estimate",
          outcome: .succeeded(recordCount: uncovered.count)
        )
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      attempts.append(
        .init(
          strategyID: "claude-local-estimate",
          outcome: .failed(redactedMessage: redactor.redact(error.localizedDescription))
        )
      )
    }
    return ProviderFetchResult(
      provider: provider,
      records: records,
      attempts: attempts,
      refreshedSourceIDs: refreshedSourceIDs,
      fetchedAt: fetchedAt
    )
  }

  static func productionCredential(from host: CredentialHost) throws -> ClaudeCredential? {
    if let admin = try host.environmentSecret(named: "ANTHROPIC_ADMIN_KEY") {
      return .adminKey(admin)
    }
    return try host.environmentSecret(named: "ANTHROPIC_OAUTH_TOKEN")
      .map(ClaudeCredential.bearerToken)
  }

  private func message(for error: Error) -> String {
    if case ProviderClientError.httpStatus(let status) = error, status == 401 || status == 403 {
      return "Authorization failed (HTTP \(status))."
    }
    return redactor.redact(error.localizedDescription)
  }

  private func fingerprint(for credential: ClaudeCredential?) -> String {
    let identity: Secret
    switch credential {
    case .adminKey(let secret), .bearerToken(let secret):
      identity = secret
    case nil:
      identity = localIdentity
    }
    return fingerprinter.fingerprint(identity: identity, namespace: "claude-account")
  }

  private static func reaccount(
    _ record: SpendRecord,
    accountFingerprint: String
  ) throws -> SpendRecord {
    let id = stableIdentifier([accountFingerprint, record.id])
    return try SpendRecord(
      id: id,
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
