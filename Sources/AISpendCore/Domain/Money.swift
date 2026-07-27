import Foundation

public struct Money: Codable, Hashable, Comparable, Sendable {
  public let amount: Decimal
  public let currency: String

  public init(_ amount: Decimal, currency: String = "USD") {
    self.amount = amount
    self.currency = currency
  }

  public static let zero = Money(0)

  public static func + (lhs: Money, rhs: Money) -> Money {
    Money(lhs.amount + rhs.amount, currency: lhs.currency)
  }

  public static func - (lhs: Money, rhs: Money) -> Money {
    Money(lhs.amount - rhs.amount, currency: lhs.currency)
  }

  public static func * (lhs: Money, rhs: Decimal) -> Money {
    Money(lhs.amount * rhs, currency: lhs.currency)
  }

  public static func < (lhs: Money, rhs: Money) -> Bool {
    lhs.amount < rhs.amount
  }

  private enum CodingKeys: String, CodingKey {
    case amount
    case currency
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let currency = try container.decode(String.self, forKey: .currency)
    guard currency == "USD" else {
      throw DecodingError.dataCorruptedError(
        forKey: .currency,
        in: container,
        debugDescription: "Money supports USD only."
      )
    }

    let amountString = try container.decode(String.self, forKey: .amount)
    guard
      let amount = Decimal(
        string: amountString,
        locale: Locale(identifier: "en_US_POSIX")
      )
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .amount,
        in: container,
        debugDescription: "Money amount must be a base-10 decimal string."
      )
    }

    self.init(amount, currency: currency)
  }

  public func encode(to encoder: Encoder) throws {
    guard currency == "USD" else {
      throw EncodingError.invalidValue(
        currency,
        EncodingError.Context(
          codingPath: encoder.codingPath,
          debugDescription: "Money supports USD only."
        )
      )
    }

    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(
      NSDecimalNumber(decimal: amount).stringValue,
      forKey: .amount
    )
    try container.encode(currency, forKey: .currency)
  }
}
