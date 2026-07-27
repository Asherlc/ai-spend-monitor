import AISpendCore
import Foundation

public struct ClaudeAdapter: ProviderAdapter {
  public let provider = ProviderID.claude

  private let credential: @Sendable () throws -> ClaudeCredential?
  private let actual: @Sendable (MonthWindow, ClaudeCredential) async throws -> [ClaudeCostRow]
  private let local: @Sendable (MonthWindow, Date) throws -> LocalLogScanResult
  private let now: @Sendable () -> Date
  private let redactor: Redactor

  init(
    credential: @escaping @Sendable () throws -> ClaudeCredential?,
    actual: @escaping @Sendable (MonthWindow, ClaudeCredential) async throws -> [ClaudeCostRow],
    local: @escaping @Sendable (MonthWindow, Date) throws -> LocalLogScanResult,
    now: @escaping @Sendable () -> Date,
    redactor: Redactor = Redactor()
  ) {
    self.credential = credential
    self.actual = actual
    self.local = local
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
      credential: {
        if let admin = try credentialHost.environmentSecret(named: "ANTHROPIC_ADMIN_KEY") {
          return .adminKey(admin)
        }
        return try credentialHost.environmentSecret(named: "ANTHROPIC_API_KEY")
          .map(ClaudeCredential.adminKey)
      },
      actual: { window, credential in
        try await client.fetch(window: window, credential: credential)
      },
      local: scanner.scan,
      now: now
    )
  }

  public func fetch(window: MonthWindow) async throws -> ProviderFetchResult {
    let fetchedAt = now()
    var records: [SpendRecord] = []
    var attempts: [SourceAttempt] = []

    do {
      if let credential = try credential() {
        let rows = try await actual(window, credential)
        let actualRecords = try rows.enumerated().map { index, row in
          try SpendRecord(
            id: "claude-actual-\(row.start.timeIntervalSince1970)-\(index)",
            provider: .claude,
            accountFingerprint: "local",
            model: row.model ?? Self.model(for: row.description),
            intervalStart: row.start,
            intervalEnd: row.end,
            amount: Money(row.amount),
            quality: .actual,
            sourceID: "claude-cost-report",
            observationID: "claude-cost-\(row.start.timeIntervalSince1970)-\(index)",
            fetchedAt: fetchedAt,
            estimate: nil
          )
        }
        records.append(contentsOf: actualRecords)
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
    } catch {
      attempts.append(
        .init(strategyID: "claude-actual", outcome: .failed(redactedMessage: message(for: error)))
      )
    }

    do {
      let result = try local(window, fetchedAt)
      records.append(contentsOf: result.records)
      attempts.append(
        .init(
          strategyID: "claude-local-estimate",
          outcome: .succeeded(recordCount: result.records.count)
        )
      )
    } catch {
      attempts.append(
        .init(
          strategyID: "claude-local-estimate",
          outcome: .failed(redactedMessage: redactor.redact(error.localizedDescription))
        )
      )
    }
    return ProviderFetchResult(
      provider: provider, records: records, attempts: attempts, fetchedAt: fetchedAt)
  }

  private func message(for error: Error) -> String {
    if case ProviderClientError.httpStatus(let status) = error, status == 401 || status == 403 {
      return "Authorization failed (HTTP \(status))."
    }
    return redactor.redact(error.localizedDescription)
  }

  private static func model(for description: String) -> String {
    description.lowercased().replacingOccurrences(of: " ", with: "-")
  }
}
