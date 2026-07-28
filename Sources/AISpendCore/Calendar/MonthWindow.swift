import Foundation

public struct MonthWindow: Hashable, Sendable {
  public let start: Date
  public let end: Date

  public init(start: Date, end: Date) {
    self.start = start
    self.end = end
  }

  public var duration: TimeInterval {
    end.timeIntervalSince(start)
  }

  public static func current(
    containing date: Date,
    calendar: Calendar
  ) throws -> MonthWindow {
    guard let interval = calendar.dateInterval(of: .month, for: date) else {
      throw MonthWindowError.cannotCalculateMonthBoundaries
    }

    return MonthWindow(start: interval.start, end: interval.end)
  }

  public func contains(_ date: Date) -> Bool {
    date >= start && date < end
  }
}

public enum MonthWindowError: Error {
  case cannotCalculateMonthBoundaries
}
