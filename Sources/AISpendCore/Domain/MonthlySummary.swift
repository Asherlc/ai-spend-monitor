public struct ModelSpendSummary: Hashable, Sendable {
  public let model: String
  public let actual: Money
  public let estimated: Money

  public var total: Money {
    actual + estimated
  }

  public init(model: String, actual: Money, estimated: Money) {
    self.model = model
    self.actual = actual
    self.estimated = estimated
  }
}

public struct ProviderSpendSummary: Identifiable, Hashable, Sendable {
  public let id: ProviderID
  public let actual: Money
  public let estimated: Money
  public let models: [ModelSpendSummary]

  public var total: Money {
    actual + estimated
  }

  public init(
    id: ProviderID,
    actual: Money,
    estimated: Money,
    models: [ModelSpendSummary]
  ) {
    self.id = id
    self.actual = actual
    self.estimated = estimated
    self.models = models
  }
}

public struct MonthlySummary: Hashable, Sendable {
  public let total: Money
  public let actual: Money
  public let estimated: Money
  public let providers: [ProviderSpendSummary]
  public let isPartial: Bool

  public init(
    total: Money,
    actual: Money,
    estimated: Money,
    providers: [ProviderSpendSummary],
    isPartial: Bool
  ) {
    self.total = total
    self.actual = actual
    self.estimated = estimated
    self.providers = providers
    self.isPartial = isPartial
  }
}
