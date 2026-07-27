import Foundation

public struct SourceAttempt: Hashable, Sendable {
  public let strategyID: String
  public let outcome: Outcome

  public init(strategyID: String, outcome: Outcome) {
    self.strategyID = strategyID
    self.outcome = outcome
  }

  public enum Outcome: Hashable, Sendable {
    case succeeded(recordCount: Int)
    case unavailable(reason: String)
    case failed(redactedMessage: String)
  }
}

public struct ProviderFetchResult: Sendable {
  public let provider: ProviderID
  public let records: [SpendRecord]
  public let attempts: [SourceAttempt]
  public let fetchedAt: Date

  public init(
    provider: ProviderID,
    records: [SpendRecord],
    attempts: [SourceAttempt],
    fetchedAt: Date
  ) {
    self.provider = provider
    self.records = records
    self.attempts = attempts
    self.fetchedAt = fetchedAt
  }
}

public protocol ProviderAdapter: Sendable {
  var provider: ProviderID { get }
  func fetch(window: MonthWindow) async throws -> ProviderFetchResult
}
