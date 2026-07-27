import Foundation

public enum BudgetAlertKind: String, Hashable, Sendable {
  case immediate
  case dailyReminder
}

public struct BudgetAlertDecision: Sendable {
  public let budgetID: UUID
  public let kind: BudgetAlertKind
  public let title: String
  public let body: String
  public let localDay: String
  public let nextState: StoredBudgetAlertState

  public init(
    budgetID: UUID,
    kind: BudgetAlertKind,
    title: String,
    body: String,
    localDay: String,
    nextState: StoredBudgetAlertState
  ) {
    self.budgetID = budgetID
    self.kind = kind
    self.title = title
    self.body = body
    self.localDay = localDay
    self.nextState = nextState
  }
}

public struct BudgetAlertEvaluation: Sendable {
  public let decisions: [BudgetAlertDecision]
  public let stateUpdates: [StoredBudgetAlertState]

  public init(
    decisions: [BudgetAlertDecision],
    stateUpdates: [StoredBudgetAlertState]
  ) {
    self.decisions = decisions
    self.stateUpdates = stateUpdates
  }
}

public struct BudgetAlertEngine: Sendable {
  public init() {}

  public func decisions(
    pacing: PacingResult,
    summary: MonthlySummary,
    budgets: [BudgetDefinition],
    storedStates: [UUID: StoredBudgetAlertState],
    now: Date,
    calendar: Calendar,
    allDataIsStale: Bool
  ) -> [BudgetAlertDecision] {
    evaluate(
      pacing: pacing,
      summary: summary,
      budgets: budgets,
      storedStates: storedStates,
      now: now,
      calendar: calendar,
      allDataIsStale: allDataIsStale
    ).decisions
  }

  public func evaluate(
    pacing: PacingResult,
    summary: MonthlySummary,
    budgets: [BudgetDefinition],
    storedStates: [UUID: StoredBudgetAlertState],
    now: Date,
    calendar: Calendar,
    allDataIsStale: Bool
  ) -> BudgetAlertEvaluation {
    guard !allDataIsStale else {
      return BudgetAlertEvaluation(decisions: [], stateUpdates: [])
    }

    let enabledBudgets =
      budgets
      .filter(\.isEnabled)
      .sorted(by: Self.ordersBudgets)
    let evaluations = Dictionary(
      uniqueKeysWithValues: pacing.budgets.map { ($0.id, $0) }
    )
    var decisions: [BudgetAlertDecision] = []
    var stateUpdates: [StoredBudgetAlertState] = []

    for budget in enabledBudgets {
      guard let evaluation = evaluations[budget.id] else {
        continue
      }
      let storedState =
        storedStates[budget.id]
        ?? StoredBudgetAlertState(budgetID: budget.id)

      switch evaluation.state {
      case .offPace:
        if storedState.lastPacingState == nil
          || storedState.lastPacingState == .unknown
        {
          var baselineState = storedState
          baselineState.lastPacingState = .offPace
          baselineState.lastReminderAt = now
          stateUpdates.append(baselineState)
          continue
        }
        if let decision = alertDecision(
          budget: budget,
          pacing: pacing,
          summary: summary,
          storedState: storedState,
          now: now,
          calendar: calendar
        ) {
          decisions.append(decision)
        }
      case .onPace, .collecting:
        if let update = nonAlertStateUpdate(
          evaluation.state,
          storedState: storedState
        ) {
          stateUpdates.append(update)
        }
      case .unknown:
        continue
      }
    }

    return BudgetAlertEvaluation(
      decisions: decisions,
      stateUpdates: stateUpdates
    )
  }

  private func alertDecision(
    budget: BudgetDefinition,
    pacing: PacingResult,
    summary: MonthlySummary,
    storedState: StoredBudgetAlertState,
    now: Date,
    calendar: Calendar
  ) -> BudgetAlertDecision? {
    guard let projection = pacing.projection else {
      return nil
    }

    let kind: BudgetAlertKind
    if storedState.lastPacingState != .offPace {
      kind = .immediate
    } else if Self.wasAlerted(
      state: storedState,
      onSameDayAs: now,
      calendar: calendar
    ) {
      return nil
    } else {
      kind = .dailyReminder
    }

    var nextState = storedState
    nextState.lastPacingState = .offPace
    switch kind {
    case .immediate:
      nextState.lastImmediateAlertAt = now
    case .dailyReminder:
      nextState.lastReminderAt = now
    }

    return BudgetAlertDecision(
      budgetID: budget.id,
      kind: kind,
      title: "AI spend is off pace",
      body: notificationBody(
        summary: summary,
        projection: projection,
        budget: budget
      ),
      localDay: Self.localDay(for: now, calendar: calendar),
      nextState: nextState
    )
  }

  private func nonAlertStateUpdate(
    _ pacingState: BudgetPacingState,
    storedState: StoredBudgetAlertState
  ) -> StoredBudgetAlertState? {
    let resetsReminder = pacingState == .onPace
    guard
      storedState.lastPacingState != pacingState
        || (resetsReminder && storedState.lastReminderAt != nil)
    else {
      return nil
    }

    var nextState = storedState
    nextState.lastPacingState = pacingState
    if resetsReminder {
      nextState.lastReminderAt = nil
    }
    return nextState
  }

  private func notificationBody(
    summary: MonthlySummary,
    projection: Money,
    budget: BudgetDefinition
  ) -> String {
    let provider = summary.providers.sorted(by: Self.ordersProviders).first
    let providerText: String
    if let provider {
      providerText =
        "\(Self.displayName(for: provider.id)) "
        + "(\(Self.currencyString(provider.total)))"
    } else {
      providerText = "No provider spend"
    }

    return
      "Spent \(Self.currencyString(summary.total)); projected "
      + "\(Self.currencyString(projection)) against "
      + "\(Self.currencyString(budget.limit)). "
      + "Largest provider: \(providerText)."
  }

  private static func wasAlerted(
    state: StoredBudgetAlertState,
    onSameDayAs date: Date,
    calendar: Calendar
  ) -> Bool {
    [state.lastImmediateAlertAt, state.lastReminderAt]
      .compactMap { $0 }
      .contains { calendar.isDate($0, inSameDayAs: date) }
  }

  private static func localDay(
    for date: Date,
    calendar: Calendar
  ) -> String {
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    return String(
      format: "%04d-%02d-%02d",
      components.year ?? 0,
      components.month ?? 0,
      components.day ?? 0
    )
  }

  private static func ordersBudgets(
    _ lhs: BudgetDefinition,
    _ rhs: BudgetDefinition
  ) -> Bool {
    if lhs.limit != rhs.limit {
      return lhs.limit < rhs.limit
    }
    return lhs.id.uuidString < rhs.id.uuidString
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

  private static func displayName(for provider: ProviderID) -> String {
    switch provider {
    case .cursor:
      "Cursor"
    case .claude:
      "Claude"
    case .openAI:
      "OpenAI"
    }
  }

  private static func currencyString(_ money: Money) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = true
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    let amount =
      formatter.string(from: NSDecimalNumber(decimal: money.amount))
      ?? "0.00"
    return "$\(amount)"
  }
}
