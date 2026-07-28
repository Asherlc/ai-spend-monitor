import AISpendCore
import Foundation
import SwiftUI

public struct MenuBarBudgetProgress: Equatable, Sendable {
  public let fraction: Double
  public let percentage: Decimal
  public let limit: Money

  public var accessibilityLabel: String {
    let percentageText = NSDecimalNumber(decimal: percentage).stringValue
    return "\(percentageText)% of \(SpendFormatting.currency(limit)) budget used"
  }

  public init(
    fraction: Double,
    percentage: Decimal,
    limit: Money
  ) {
    self.fraction = fraction
    self.percentage = percentage
    self.limit = limit
  }
}
