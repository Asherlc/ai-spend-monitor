import Foundation

public enum BudgetExhaustionForecast: Hashable, Sendable {
  case reached
  case projected(Date)
  case lastsThroughMonth
}

public struct BudgetEvaluation: Identifiable, Hashable, Sendable {
  public let id: UUID
  public let limit: Money
  public let state: BudgetPacingState
  public let currentMargin: Money?
  public let projectedMargin: Money?
  public let exhaustionForecast: BudgetExhaustionForecast?
  public let usageFraction: Double?
}

public struct PacingResult: Hashable, Sendable {
  public let projection: Money?
  public let isCollecting: Bool
  public let isPartial: Bool
  public let budgets: [BudgetEvaluation]
}

public struct PacingEngine: Sendable {
  public init() {}

  public func evaluate(
    spend: Money,
    budgets: [BudgetDefinition],
    now: Date,
    window: MonthWindow,
    hasAnyData: Bool,
    allDataIsStale: Bool,
    isPartial: Bool = false
  ) -> PacingResult {
    let enabledBudgets =
      budgets
      .filter(\.isEnabled)
      .sorted { $0.limit < $1.limit }

    guard hasAnyData else {
      return PacingResult(
        projection: nil,
        isCollecting: false,
        isPartial: isPartial,
        budgets: enabledBudgets.map {
          BudgetEvaluation(
            id: $0.id,
            limit: $0.limit,
            state: .unknown,
            currentMargin: nil,
            projectedMargin: nil,
            exhaustionForecast: nil,
            usageFraction: nil
          )
        }
      )
    }

    let elapsed = now.timeIntervalSince(window.start)
    let collectionDuration: TimeInterval = 6 * 60 * 60
    let isCollecting = elapsed < collectionDuration
    guard !isCollecting, elapsed > 0, window.duration > 0 else {
      return PacingResult(
        projection: nil,
        isCollecting: true,
        isPartial: isPartial || allDataIsStale,
        budgets: enabledBudgets.map {
          BudgetEvaluation(
            id: $0.id,
            limit: $0.limit,
            state: .collecting,
            currentMargin: $0.limit - spend,
            projectedMargin: nil,
            exhaustionForecast: nil,
            usageFraction: usageFraction(
              spend: spend,
              limit: $0.limit
            )
          )
        }
      )
    }

    let projection = spend * (Decimal(window.duration) / Decimal(elapsed))
    return PacingResult(
      projection: projection,
      isCollecting: false,
      isPartial: isPartial || allDataIsStale,
      budgets: enabledBudgets.map { budget in
        BudgetEvaluation(
          id: budget.id,
          limit: budget.limit,
          state: projection <= budget.limit ? .onPace : .offPace,
          currentMargin: budget.limit - spend,
          projectedMargin: budget.limit - projection,
          exhaustionForecast: exhaustionForecast(
            spend: spend,
            budget: budget,
            now: now,
            elapsed: elapsed,
            monthEnd: window.end
          ),
          usageFraction: usageFraction(
            spend: spend,
            limit: budget.limit
          )
        )
      }
    )
  }

  private func exhaustionForecast(
    spend: Money,
    budget: BudgetDefinition,
    now: Date,
    elapsed: TimeInterval,
    monthEnd: Date
  ) -> BudgetExhaustionForecast {
    guard spend < budget.limit else {
      return .reached
    }
    guard spend.amount > 0 else {
      return .lastsThroughMonth
    }

    let remaining = budget.limit - spend
    let remainingDuration = NSDecimalNumber(
      decimal: remaining.amount * Decimal(elapsed) / spend.amount
    ).doubleValue
    let projectedDate = now.addingTimeInterval(remainingDuration)
    return projectedDate < monthEnd
      ? .projected(projectedDate)
      : .lastsThroughMonth
  }

  private func usageFraction(spend: Money, limit: Money) -> Double {
    let ratio = spend.amount / limit.amount
    let clampedRatio = min(max(ratio, 0), 1)
    return NSDecimalNumber(decimal: clampedRatio).doubleValue
  }
}
