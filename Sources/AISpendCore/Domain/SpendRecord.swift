import Foundation

public struct EstimateMetadata: Codable, Hashable, Sendable {
  public let inputTokens: Int
  public let cachedInputTokens: Int
  public let outputTokens: Int
  public let catalogVersion: String

  public init(
    inputTokens: Int,
    cachedInputTokens: Int,
    outputTokens: Int,
    catalogVersion: String
  ) {
    self.inputTokens = inputTokens
    self.cachedInputTokens = cachedInputTokens
    self.outputTokens = outputTokens
    self.catalogVersion = catalogVersion
  }
}

public struct SpendRecord: Identifiable, Codable, Hashable, Sendable {
  public let id: String
  public let provider: ProviderID
  public let accountFingerprint: String
  public let model: String
  public let intervalStart: Date
  public let intervalEnd: Date
  public let amount: Money
  public let quality: SpendQuality
  public let sourceID: String
  public let observationID: String
  public let fetchedAt: Date
  public let estimate: EstimateMetadata?

  public init(
    id: String,
    provider: ProviderID,
    accountFingerprint: String,
    model: String,
    intervalStart: Date,
    intervalEnd: Date,
    amount: Money,
    quality: SpendQuality,
    sourceID: String,
    observationID: String,
    fetchedAt: Date,
    estimate: EstimateMetadata?
  ) throws {
    guard intervalEnd > intervalStart else {
      throw ValidationError.invalidInterval
    }
    guard amount.amount >= 0 else {
      throw ValidationError.negativeAmount
    }
    guard amount.currency == "USD" else {
      throw ValidationError.unsupportedCurrency
    }
    guard !sourceID.isEmpty else {
      throw ValidationError.emptySourceID
    }

    self.id = id
    self.provider = provider
    self.accountFingerprint = accountFingerprint
    self.model = model
    self.intervalStart = intervalStart
    self.intervalEnd = intervalEnd
    self.amount = amount
    self.quality = quality
    self.sourceID = sourceID
    self.observationID = observationID
    self.fetchedAt = fetchedAt
    self.estimate = estimate
  }

  enum ValidationError: Error {
    case invalidInterval
    case negativeAmount
    case unsupportedCurrency
    case emptySourceID
  }
}
