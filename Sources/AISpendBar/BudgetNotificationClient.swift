import AISpendCore
import Foundation
import UserNotifications

struct BudgetNotificationTransport: Sendable {
  private let authorize: @MainActor @Sendable (UNAuthorizationOptions) async throws -> Bool
  private let addRequest: @MainActor @Sendable (UNNotificationRequest) async throws -> Void

  init(
    requestAuthorization:
      @escaping @MainActor @Sendable (UNAuthorizationOptions) async throws ->
      Bool,
    add:
      @escaping @MainActor @Sendable (UNNotificationRequest) async throws ->
      Void
  ) {
    authorize = requestAuthorization
    addRequest = add
  }

  @MainActor
  func requestAuthorization(
    options: UNAuthorizationOptions
  ) async throws -> Bool {
    try await authorize(options)
  }

  @MainActor
  func add(_ request: UNNotificationRequest) async throws {
    try await addRequest(request)
  }

  @MainActor
  static func live(
    center: UNUserNotificationCenter = .current()
  ) -> BudgetNotificationTransport {
    BudgetNotificationTransport(
      requestAuthorization: { options in
        try await center.requestAuthorization(options: options)
      },
      add: { request in
        try await center.add(request)
      }
    )
  }
}

@MainActor
final class BudgetNotificationClient {
  private let transport: BudgetNotificationTransport

  init(center: UNUserNotificationCenter = .current()) {
    transport = .live(center: center)
  }

  init(transport: BudgetNotificationTransport) {
    self.transport = transport
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

    return try await transport.requestAuthorization(options: [.alert, .sound])
  }

  func deliver(
    _ decision: BudgetAlertDecision
  ) async throws -> StoredBudgetAlertState {
    let content = UNMutableNotificationContent()
    content.title = decision.title
    content.body = decision.body
    content.sound = .default

    let request = UNNotificationRequest(
      identifier: notificationIdentifier(for: decision),
      content: content,
      trigger: nil
    )
    try await transport.add(request)
    return decision.nextState
  }

  private func notificationIdentifier(
    for decision: BudgetAlertDecision
  ) -> String {
    let kind =
      switch decision.kind {
      case .immediate:
        "immediate"
      case .dailyReminder:
        "daily-reminder"
      }
    return
      "budget-\(decision.budgetID.uuidString.lowercased())-"
      + "\(decision.localDay)-\(kind)"
  }
}
