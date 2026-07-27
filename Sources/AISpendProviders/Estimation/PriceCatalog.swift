import AISpendCore
import Foundation

public enum PriceCatalogError: Error, Equatable, Sendable {
  case resourceUnavailable
  case invalidCatalog
  case invalidUsage
  case unknownModel(String)
}

public struct PriceCatalog: Sendable {
  public let version: String

  private let currency: String
  private let models: [String: ModelPrice]

  public static func bundled() throws -> PriceCatalog {
    guard let url = Bundle.module.url(forResource: "model-prices", withExtension: "json") else {
      throw PriceCatalogError.resourceUnavailable
    }
    do {
      let resource = try JSONDecoder().decode(
        CatalogResource.self,
        from: Data(contentsOf: url)
      )
      guard resource.currency == "USD" else {
        throw PriceCatalogError.invalidCatalog
      }
      return PriceCatalog(
        version: resource.version,
        currency: resource.currency,
        models: resource.models
      )
    } catch let error as PriceCatalogError {
      throw error
    } catch {
      throw PriceCatalogError.invalidCatalog
    }
  }

  public func estimate(_ usage: LocalUsage) throws -> Money {
    guard
      usage.inputTokens >= 0,
      usage.cacheCreation5mInputTokens >= 0,
      usage.cacheCreation1hInputTokens >= 0,
      usage.cachedInputTokens >= 0,
      usage.outputTokens >= 0
    else {
      throw PriceCatalogError.invalidUsage
    }
    guard let price = models[usage.model] else {
      throw PriceCatalogError.unknownModel(usage.model)
    }
    guard
      usage.cacheCreation5mInputTokens == 0 || price.cacheWrite5mPerMillion != nil,
      usage.cacheCreation1hInputTokens == 0 || price.cacheWrite1hPerMillion != nil
    else {
      throw PriceCatalogError.invalidUsage
    }
    let million = Decimal(1_000_000)
    let amount =
      Decimal(usage.inputTokens) * price.inputPerMillion / million
      + Decimal(usage.cacheCreation5mInputTokens) * (price.cacheWrite5mPerMillion ?? 0) / million
      + Decimal(usage.cacheCreation1hInputTokens) * (price.cacheWrite1hPerMillion ?? 0) / million
      + Decimal(usage.cachedInputTokens) * price.cachedInputPerMillion / million
      + Decimal(usage.outputTokens) * price.outputPerMillion / million
    return Money(amount, currency: currency)
  }
}

private struct CatalogResource: Decodable {
  let version: String
  let currency: String
  let models: [String: ModelPrice]
}

private struct ModelPrice: Decodable, Sendable {
  let inputPerMillion: Decimal
  let cacheWrite5mPerMillion: Decimal?
  let cacheWrite1hPerMillion: Decimal?
  let cachedInputPerMillion: Decimal
  let outputPerMillion: Decimal

  private enum CodingKeys: String, CodingKey {
    case inputPerMillion
    case cacheWrite5mPerMillion
    case cacheWrite1hPerMillion
    case cachedInputPerMillion
    case outputPerMillion
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    inputPerMillion = try container.decimal(forKey: .inputPerMillion)
    cacheWrite5mPerMillion =
      container.contains(.cacheWrite5mPerMillion)
      ? try container.decimal(forKey: .cacheWrite5mPerMillion) : nil
    cacheWrite1hPerMillion =
      container.contains(.cacheWrite1hPerMillion)
      ? try container.decimal(forKey: .cacheWrite1hPerMillion) : nil
    cachedInputPerMillion = try container.decimal(forKey: .cachedInputPerMillion)
    outputPerMillion = try container.decimal(forKey: .outputPerMillion)
  }
}

extension KeyedDecodingContainer {
  fileprivate func decimal(
    forKey key: Key
  ) throws -> Decimal {
    guard contains(key) else {
      throw PriceCatalogError.invalidCatalog
    }
    let value = try decode(String.self, forKey: key)
    guard
      let decimal = Decimal(
        string: value,
        locale: Locale(identifier: "en_US_POSIX")
      )
    else {
      throw PriceCatalogError.invalidCatalog
    }
    return decimal
  }
}
