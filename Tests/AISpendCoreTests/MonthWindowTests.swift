import XCTest

@testable import AISpendCore

final class MonthWindowTests: XCTestCase {
  func testLeapFebruaryUsesLocalCalendarBoundaries() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    let now = ISO8601DateFormatter().date(from: "2024-02-15T20:00:00Z")!
    let window = try MonthWindow.current(containing: now, calendar: calendar)
    XCTAssertEqual(calendar.component(.day, from: window.start), 1)
    XCTAssertEqual(calendar.component(.month, from: window.end), 3)
    XCTAssertEqual(
      window.duration,
      window.end.timeIntervalSince(window.start),
      accuracy: 0.001)
  }

  func testDurationUsesRealElapsedSecondsAcrossDaylightSavingChange() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    let now = ISO8601DateFormatter().date(from: "2024-03-15T20:00:00Z")!

    let window = try MonthWindow.current(containing: now, calendar: calendar)

    XCTAssertEqual(window.duration, (31 * 24 * 60 * 60) - 3_600, accuracy: 0.001)
  }

  func testContainsUsesHalfOpenBoundaries() {
    let start = Date(timeIntervalSince1970: 100)
    let end = Date(timeIntervalSince1970: 200)
    let window = MonthWindow(start: start, end: end)

    XCTAssertTrue(window.contains(start))
    XCTAssertTrue(window.contains(Date(timeIntervalSince1970: 199)))
    XCTAssertFalse(window.contains(end))
  }
}
