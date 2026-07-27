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

  private enum CodingKeys: String, CodingKey {
    case id
    case provider
    case accountFingerprint
    case model
    case intervalStart
    case intervalEnd
    case amount
    case quality
    case sourceID
    case observationID
    case fetchedAt
    case estimate
  }

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

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      id: container.decode(String.self, forKey: .id),
      provider: container.decode(ProviderID.self, forKey: .provider),
      accountFingerprint: container.decode(String.self, forKey: .accountFingerprint),
      model: container.decode(String.self, forKey: .model),
      intervalStart: container.decode(Date.self, forKey: .intervalStart),
      intervalEnd: container.decode(Date.self, forKey: .intervalEnd),
      amount: container.decode(Money.self, forKey: .amount),
      quality: container.decode(SpendQuality.self, forKey: .quality),
      sourceID: container.decode(String.self, forKey: .sourceID),
      observationID: container.decode(String.self, forKey: .observationID),
      fetchedAt: container.decode(Date.self, forKey: .fetchedAt),
      estimate: container.decodeIfPresent(EstimateMetadata.self, forKey: .estimate)
    )
  }

  enum ValidationError: Error {
    case invalidInterval
    case negativeAmount
    case unsupportedCurrency
    case emptySourceID
  }
}
