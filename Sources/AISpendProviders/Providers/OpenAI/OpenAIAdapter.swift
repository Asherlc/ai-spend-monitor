import AISpendCore
import Foundation

public struct OpenAIAdapter: ProviderAdapter {
  public let provider = ProviderID.openAI

  private let credential: @Sendable () throws -> Secret?
  private let actual: @Sendable (MonthWindow, Secret) async throws -> [OpenAICostRow]
  private let local: @Sendable (MonthWindow, Date) throws -> LocalLogScanResult
  private let now: @Sendable () -> Date
  private let redactor: Redactor

  init(
    credential: @escaping @Sendable () throws -> Secret?,
    actual: @escaping @Sendable (MonthWindow, Secret) async throws -> [OpenAICostRow],
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
    scanner: CodexLogScanner,
    httpClient: HTTPClient = HTTPClient(),
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    let client = OpenAICostClient(httpClient: httpClient)
    self.init(
      credential: {
        if let admin = try credentialHost.environmentSecret(named: "OPENAI_ADMIN_KEY") {
          return admin
        }
        return try credentialHost.environmentSecret(named: "OPENAI_API_KEY")
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
            id: "openai-actual-\(row.start.timeIntervalSince1970)-\(index)",
            provider: .openAI,
            accountFingerprint: "local",
            model: row.model,
            intervalStart: row.start,
            intervalEnd: row.end,
            amount: Money(row.amount),
            quality: .actual,
            sourceID: "openai-organization-costs",
            observationID: "openai-cost-\(row.start.timeIntervalSince1970)-\(index)",
            fetchedAt: fetchedAt,
            estimate: nil
          )
        }
        records.append(contentsOf: actualRecords)
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
    } catch {
      attempts.append(
        .init(strategyID: "openai-actual", outcome: .failed(redactedMessage: message(for: error)))
      )
    }

    do {
      let result = try local(window, fetchedAt)
      records.append(contentsOf: result.records)
      attempts.append(
        .init(
          strategyID: "openai-local-estimate",
          outcome: .succeeded(recordCount: result.records.count)
        )
      )
    } catch {
      attempts.append(
        .init(
          strategyID: "openai-local-estimate",
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
}
