import AISpendCore
import XCTest

@testable import AISpendBar

@MainActor
final class AppLifecycleControllerTests: XCTestCase {
  func testStartLaunchesOnceAndSchedulesPeriodicRefreshWithoutDuplicateLoops() async throws {
    var reasons: [RefreshReason] = []
    let lifecycle = AppLifecycleController(
      interval: .seconds(900),
      refresh: { reasons.append($0) },
      sleep: { _ in try await ContinuousClock().sleep(for: .milliseconds(5)) }
    )

    lifecycle.start()
    lifecycle.start()

    try await waitUntil { reasons.count >= 2 }

    XCTAssertEqual(reasons[0], .launch)
    XCTAssertEqual(reasons[1], .periodic)
    lifecycle.stop()
  }

  func testStopCancelsFuturePeriodicRefreshes() async throws {
    var reasons: [RefreshReason] = []
    let lifecycle = AppLifecycleController(
      interval: .seconds(900),
      refresh: { reasons.append($0) },
      sleep: { _ in try await ContinuousClock().sleep(for: .milliseconds(5)) }
    )

    lifecycle.start()
    try await waitUntil { reasons.count >= 2 }
    lifecycle.stop()
    let countAfterStop = reasons.count
    try await ContinuousClock().sleep(for: .milliseconds(20))

    XCTAssertFalse(lifecycle.isRunning)
    XCTAssertEqual(reasons.count, countAfterStop)
  }

  private func waitUntil(
    timeout: Duration = .seconds(1),
    condition: @escaping @MainActor () -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
      guard clock.now < deadline else {
        XCTFail("Timed out waiting for lifecycle event")
        return
      }
      try await clock.sleep(for: .milliseconds(1))
    }
  }
}
