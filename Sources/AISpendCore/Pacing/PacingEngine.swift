import Foundation

public struct BudgetEvaluation: Identifiable, Hashable, Sendable {
  public let id: UUID
  public let limit: Money
  public let state: BudgetPacingState
  public let projectedMargin: Money?
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
            projectedMargin: nil
          )
        }
      )
    }

    let elapsed = now.timeIntervalSince(window.start)
    let collectionDuration: TimeInterval = 6 * 60 * 60
    let isCollecting =
      window.duration > collectionDuration && elapsed < collectionDuration
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
            projectedMargin: nil
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
          projectedMargin: budget.limit - projection
        )
      }
    )
  }
}
