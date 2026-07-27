import AISpendCore
import Foundation
import UserNotifications

@MainActor
final class BudgetNotificationClient {
  private let center: UNUserNotificationCenter

  init(center: UNUserNotificationCenter = .current()) {
    self.center = center
  }

  @discardableResult
  func requestAuthorizationIfFirstEnabledBudget(
    previousBudgets: [BudgetDefinition],
    currentBudgets: [BudgetDefinition]
  ) async throws -> Bool {
    guard
      !previousBudgets.contains(where: \.isEnabled),
      currentBudgets.contains(where: \.isEnabled)
    else {
      return false
    }

    return try await center.requestAuthorization(options: [.alert, .sound])
  }

  func deliver(
    _ decision: BudgetAlertDecision,
    now: Date,
    calendar: Calendar
  ) async throws -> StoredBudgetAlertState {
    let content = UNMutableNotificationContent()
    content.title = decision.title
    content.body = decision.body
    content.sound = .default

    let request = UNNotificationRequest(
      identifier: notificationIdentifier(
        for: decision,
        now: now,
        calendar: calendar
      ),
      content: content,
      trigger: nil
    )
    try await center.add(request)
    return decision.nextState
  }

  private func notificationIdentifier(
    for decision: BudgetAlertDecision,
    now: Date,
    calendar: Calendar
  ) -> String {
    let components = calendar.dateComponents([.year, .month, .day], from: now)
    let year = components.year ?? 0
    let month = components.month ?? 0
    let day = components.day ?? 0
    let localDay = String(format: "%04d-%02d-%02d", year, month, day)
    let kind =
      switch decision.kind {
      case .immediate:
        "immediate"
      case .dailyReminder:
        "daily-reminder"
      }
    return
      "budget-\(decision.budgetID.uuidString.lowercased())-"
      + "\(localDay)-\(kind)"
  }
}
