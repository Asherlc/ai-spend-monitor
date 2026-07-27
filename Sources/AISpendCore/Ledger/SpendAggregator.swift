import Foundation

public enum Freshness: Hashable, Sendable {
  case fresh
  case stale(age: TimeInterval)
  case unavailable(message: String)
}

public struct SpendAggregator: Sendable {
  public init() {}

  public func summarize(
    records: [SpendRecord],
    enabledProviders: Set<ProviderID>,
    window: MonthWindow,
    providerFreshness: [ProviderID: Freshness]
  ) -> MonthlySummary {
    let includedRecords = records.filter {
      enabledProviders.contains($0.provider) && window.contains($0.intervalStart)
    }
    let providerGroups = Dictionary(grouping: includedRecords, by: \.provider)
    let providers = providerGroups.map { provider, records in
      let modelGroups = Dictionary(grouping: records, by: \.model)
      let models = modelGroups.map { model, records in
        ModelSpendSummary(
          model: model,
          actual: Self.total(records, quality: .actual),
          estimated: Self.total(records, quality: .estimated)
        )
      }.sorted(by: Self.ordersModels)

      return ProviderSpendSummary(
        id: provider,
        actual: Self.total(records, quality: .actual),
        estimated: Self.total(records, quality: .estimated),
        models: models
      )
    }.sorted(by: Self.ordersProviders)

    let actual = Self.total(includedRecords, quality: .actual)
    let estimated = Self.total(includedRecords, quality: .estimated)
    let isPartial = enabledProviders.contains { provider in
      switch providerFreshness[provider] {
      case .stale, .unavailable:
        true
      case .fresh, .none:
        false
      }
    }

    return MonthlySummary(
      total: actual + estimated,
      actual: actual,
      estimated: estimated,
      providers: providers,
      isPartial: isPartial
    )
  }

  private static func total(
    _ records: [SpendRecord],
    quality: SpendQuality
  ) -> Money {
    records
      .filter { $0.quality == quality }
      .reduce(.zero) { $0 + $1.amount }
  }

  private static func ordersModels(
    _ lhs: ModelSpendSummary,
    _ rhs: ModelSpendSummary
  ) -> Bool {
    if lhs.total != rhs.total {
      return lhs.total > rhs.total
    }
    return lhs.model < rhs.model
  }

  private static func ordersProviders(
    _ lhs: ProviderSpendSummary,
    _ rhs: ProviderSpendSummary
  ) -> Bool {
    if lhs.total != rhs.total {
      return lhs.total > rhs.total
    }
    return lhs.id.rawValue < rhs.id.rawValue
  }
}
