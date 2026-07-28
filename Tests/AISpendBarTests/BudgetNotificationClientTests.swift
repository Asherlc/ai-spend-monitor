import AISpendCore
import Foundation
import UserNotifications
import XCTest

@testable import AISpendBar

@MainActor
final class BudgetNotificationClientTests: XCTestCase {
  func testNotificationCompletionCanArriveOffMainActor() async throws {
    try await BudgetNotificationTransport.awaitCompletion { completion in
      DispatchQueue.global().async {
        completion(nil)
      }
    }
  }

  func testRequestsAuthorizationOnlyForFirstEnabledBudgetTransition() async throws {
    let recorder = NotificationRecorder()
    let client = BudgetNotificationClient(transport: recorder.transport())
    let disabled = budget(isEnabled: false)
    let enabled = budget(isEnabled: true)

    let disabledResult = try await client.requestAuthorizationIfFirstEnabledBudget(
      previousBudgets: [],
      currentBudgets: [disabled]
    )
    let firstEnabledResult =
      try await client.requestAuthorizationIfFirstEnabledBudget(
        previousBudgets: [disabled],
        currentBudgets: [enabled]
      )
    let repeatedResult =
      try await client.requestAuthorizationIfFirstEnabledBudget(
        previousBudgets: [enabled],
        currentBudgets: [enabled, budget(isEnabled: true)]
      )

    XCTAssertFalse(disabledResult)
    XCTAssertTrue(firstEnabledResult)
    XCTAssertFalse(repeatedResult)
    XCTAssertEqual(recorder.authorizationRequests, 1)
  }

  func testDelayedRetryUsesEvaluationLocalDayInExactStableIdentifier() async throws {
    let recorder = NotificationRecorder()
    let client = BudgetNotificationClient(transport: recorder.transport())
    let budgetID = UUID(uuidString: "A79869FA-08D4-4D6D-BEAD-8A6E1149AA10")!
    let nextState = StoredBudgetAlertState(
      budgetID: budgetID,
      lastPacingState: .offPace,
      lastImmediateAlertAt: Date(timeIntervalSince1970: 1)
    )
    let decision = BudgetAlertDecision(
      budgetID: budgetID,
      kind: .immediate,
      title: "Title",
      body: "Body",
      localDay: "2026-07-15",
      nextState: nextState
    )

    _ = try await client.deliver(decision)
    _ = try await client.deliver(decision)

    XCTAssertEqual(
      recorder.requests.map(\.identifier),
      [
        "budget-a79869fa-08d4-4d6d-bead-8a6e1149aa10-2026-07-15-immediate",
        "budget-a79869fa-08d4-4d6d-bead-8a6e1149aa10-2026-07-15-immediate",
      ]
    )
  }

  func testAcceptedRequestReturnsNextState() async throws {
    let recorder = NotificationRecorder()
    let client = BudgetNotificationClient(transport: recorder.transport())
    let decision = decision()

    let acceptedState = try await client.deliver(decision)

    XCTAssertEqual(acceptedState, decision.nextState)
    XCTAssertEqual(recorder.requests.count, 1)
  }

  func testFailedRequestThrowsWithoutReturningState() async {
    let recorder = NotificationRecorder(addError: TestError.rejected)
    let client = BudgetNotificationClient(transport: recorder.transport())
    var acceptedState: StoredBudgetAlertState?

    do {
      acceptedState = try await client.deliver(decision())
      XCTFail("Expected notification rejection")
    } catch {
      XCTAssertEqual(error as? TestError, .rejected)
    }

    XCTAssertNil(acceptedState)
    XCTAssertEqual(recorder.requests.count, 1)
  }

  private func decision() -> BudgetAlertDecision {
    let budgetID = UUID()
    return BudgetAlertDecision(
      budgetID: budgetID,
      kind: .dailyReminder,
      title: "Title",
      body: "Body",
      localDay: "2026-07-16",
      nextState: StoredBudgetAlertState(
        budgetID: budgetID,
        lastPacingState: .offPace,
        lastReminderAt: Date(timeIntervalSince1970: 2)
      )
    )
  }

  private func budget(isEnabled: Bool) -> BudgetDefinition {
    BudgetDefinition(
      id: UUID(),
      limit: Money(500),
      isEnabled: isEnabled,
      createdAt: .distantPast
    )
  }
}

private enum TestError: Error, Equatable {
  case rejected
}

@MainActor
private final class NotificationRecorder {
  private(set) var authorizationRequests = 0
  private(set) var requests: [UNNotificationRequest] = []
  private let addError: Error?

  init(addError: Error? = nil) {
    self.addError = addError
  }

  func transport() -> BudgetNotificationTransport {
    BudgetNotificationTransport(
      requestAuthorization: { [weak self] _ in
        guard let self else {
          return false
        }
        authorizationRequests += 1
        return true
      },
      add: { [weak self] request in
        guard let self else {
          return
        }
        requests.append(request)
        if let addError {
          throw addError
        }
      }
    )
  }
}
