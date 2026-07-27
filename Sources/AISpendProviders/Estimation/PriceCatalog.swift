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
      usage.cacheCreationInputTokens >= 0,
      usage.cachedInputTokens >= 0,
      usage.outputTokens >= 0
    else {
      throw PriceCatalogError.invalidUsage
    }
    guard let price = models[usage.model] else {
      throw PriceCatalogError.unknownModel(usage.model)
    }
    let million = Decimal(1_000_000)
    let amount =
      Decimal(usage.inputTokens) * price.inputPerMillion / million
      + Decimal(usage.cacheCreationInputTokens) * price.cacheWritePerMillion / million
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
  let cacheWritePerMillion: Decimal
  let cachedInputPerMillion: Decimal
  let outputPerMillion: Decimal

  private enum CodingKeys: String, CodingKey {
    case inputPerMillion
    case cacheWritePerMillion
    case cachedInputPerMillion
    case outputPerMillion
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    inputPerMillion = try container.decimal(forKey: .inputPerMillion)
    cacheWritePerMillion = try container.decimal(forKey: .cacheWritePerMillion)
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
