import AISpendCore
import Foundation

public enum SpendFormatting {
  public static func menuBar(_ money: Money) -> String {
    currency(money)
  }

  public static func currency(_ money: Money) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US")
    formatter.numberStyle = .currency
    formatter.currencyCode = money.currency
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    return formatter.string(from: NSDecimalNumber(decimal: money.amount))
      ?? "$\(NSDecimalNumber(decimal: money.amount).stringValue)"
  }

  public static func estimated(_ money: Money) -> String {
    "~\(currency(money))"
  }

  public static func share(_ ratio: Decimal) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US")
    formatter.numberStyle = .percent
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = 1
    return formatter.string(from: NSDecimalNumber(decimal: ratio)) ?? "0%"
  }

  public static func month(_ date: Date, calendar: Calendar = .current) -> String {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale.current
    formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
    return formatter.string(from: date)
  }

  public static func relative(_ date: Date, relativeTo now: Date = Date()) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: now)
  }

  public static func budgetForecast(
    _ forecast: BudgetExhaustionForecast,
    calendar: Calendar = .current,
    locale: Locale = .current
  ) -> String {
    switch forecast {
    case .reached:
      return "Budget reached"
    case .lastsThroughMonth:
      return "Lasts through month"
    case .projected(let date):
      let formatter = DateFormatter()
      formatter.calendar = calendar
      formatter.timeZone = calendar.timeZone
      formatter.locale = locale
      formatter.setLocalizedDateFormatFromTemplate("MMM d")
      return "Projected to reach \(formatter.string(from: date))"
    }
  }
}
