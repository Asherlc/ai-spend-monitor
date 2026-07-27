import AISpendCore
import Foundation

public struct CursorAdapter: ProviderAdapter {
  public let provider = ProviderID.cursor

  private let authorization: @Sendable () throws -> CursorAuthorization?
  private let usage: @Sendable (MonthWindow, CursorAuthorization) async throws -> CursorUsageResult
  private let now: @Sendable () -> Date
  private let redactor: Redactor

  init(
    authorization: @escaping @Sendable () throws -> CursorAuthorization?,
    usage: @escaping @Sendable (MonthWindow, CursorAuthorization) async throws -> CursorUsageResult,
    now: @escaping @Sendable () -> Date,
    redactor: Redactor = Redactor()
  ) {
    self.authorization = authorization
    self.usage = usage
    self.now = now
    self.redactor = redactor
  }

  public init(
    credentialHost: CredentialHost = CredentialHost(),
    stateReader: CursorStateReader = CursorStateReader(),
    httpClient: HTTPClient = HTTPClient(),
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    let client = CursorUsageClient(httpClient: httpClient)
    self.init(
      authorization: {
        if let admin = try credentialHost.environmentSecret(named: "CURSOR_ACCESS_TOKEN") {
          return .adminKey(admin)
        }
        let state = try stateReader.read()
        if let token = state.accessToken, let teamID = state.teamID {
          return .appToken(token: token, teamID: teamID)
        }
        return nil
      },
      usage: { window, authorization in
        try await client.fetch(window: window, authorization: authorization)
      },
      now: now
    )
  }

  public func fetch(window: MonthWindow) async throws -> ProviderFetchResult {
    let fetchedAt = now()
    let resolvedAuthorization: CursorAuthorization?
    do {
      resolvedAuthorization = try authorization()
    } catch SourceHostError.sourceUnavailable {
      resolvedAuthorization = nil
    }
    guard let authorization = resolvedAuthorization else {
      return ProviderFetchResult(
        provider: provider,
        records: [],
        attempts: [
          .init(
            strategyID: "cursor-actual",
            outcome: .unavailable(
              reason: "No Cursor admin credential or authenticated app state."
            )
          )
        ],
        fetchedAt: fetchedAt
      )
    }

    do {
      let result = try await usage(window, authorization)
      let modelTotal = result.modelCents.values.reduce(0, +)
      let allocations: [String: Decimal]
      var attempts: [SourceAttempt]
      if modelTotal > result.authoritativeCents {
        allocations = ["unknown": result.authoritativeCents]
        attempts = [
          .init(strategyID: "cursor-actual", outcome: .succeeded(recordCount: 1)),
          .init(
            strategyID: "cursor-attribution",
            outcome: .failed(
              redactedMessage:
                "Cursor usage schema mismatch: model attribution exceeds authoritative spend."
            )
          ),
        ]
      } else {
        var attributed = result.modelCents
        if modelTotal < result.authoritativeCents {
          attributed["unknown", default: 0] += result.authoritativeCents - modelTotal
        }
        allocations = attributed
        attempts = [
          .init(
            strategyID: "cursor-actual",
            outcome: .succeeded(recordCount: allocations.count)
          )
        ]
      }
      let records = try allocations.sorted(by: { $0.key < $1.key }).enumerated().map {
        index, allocation in
        try SpendRecord(
          id: "cursor-actual-\(allocation.key)-\(index)",
          provider: .cursor,
          accountFingerprint: "team",
          model: allocation.key,
          intervalStart: window.start,
          intervalEnd: window.end,
          amount: Money(allocation.value / 100),
          quality: .actual,
          sourceID: "cursor-team-spend",
          observationID: "cursor-spend-\(allocation.key)-\(index)",
          fetchedAt: fetchedAt,
          estimate: nil
        )
      }
      return ProviderFetchResult(
        provider: provider,
        records: records,
        attempts: attempts,
        fetchedAt: fetchedAt
      )
    } catch {
      let message: String
      if case ProviderClientError.httpStatus(let status) = error,
        status == 401 || status == 403
      {
        message = "Authorization failed (HTTP \(status))."
      } else {
        message = redactor.redact(error.localizedDescription)
      }
      return ProviderFetchResult(
        provider: provider,
        records: [],
        attempts: [
          .init(
            strategyID: "cursor-actual",
            outcome: .failed(redactedMessage: message)
          )
        ],
        fetchedAt: fetchedAt
      )
    }
  }
}
