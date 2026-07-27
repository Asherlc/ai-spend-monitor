import AISpendCore
import Foundation
import XCTest

@testable import AISpendProviders

final class ClaudeLogScannerTests: XCTestCase {
  func testScansStreamsDeduplicatesAndAggregatesOneRecordPerModelDay() throws {
    let root = try fixtureRoot(named: "claude-session")
    defer { try? FileManager.default.removeItem(at: root) }
    let calendar = utcCalendar()
    let window = try MonthWindow.current(
      containing: isoDate("2026-06-15T00:00:00Z"),
      calendar: calendar
    )
    let scanner = ClaudeLogScanner(
      sessionRoots: [root],
      priceCatalog: try PriceCatalog.bundled(),
      calendar: calendar
    )

    let result = try scanner.scan(
      window: window,
      fetchedAt: isoDate("2026-06-30T12:00:00Z")
    )

    XCTAssertEqual(result.records.count, 1)
    let record = try XCTUnwrap(result.records.first)
    XCTAssertEqual(record.provider, .claude)
    XCTAssertEqual(record.quality, .estimated)
    XCTAssertEqual(record.model, "claude-sonnet-4-5")
    XCTAssertEqual(record.amount, Money(Decimal(string: "5.025")!))
    XCTAssertEqual(record.estimate?.inputTokens, 1_000_000)
    XCTAssertEqual(record.estimate?.cacheCreation5mInputTokens, 60_000)
    XCTAssertEqual(record.estimate?.cacheCreation1hInputTokens, 40_000)
    XCTAssertEqual(record.estimate?.cachedInputTokens, 200_000)
    XCTAssertEqual(record.estimate?.outputTokens, 100_000)
    XCTAssertEqual(record.estimate?.catalogVersion, "2026-07-27")
    XCTAssertEqual(result.diagnostics.count, 1)
  }

  func testObservationIDIsDeterministicAcrossRootOrdering() throws {
    let first = try fixtureRoot(named: "claude-session")
    let second = try emptyRoot()
    defer {
      try? FileManager.default.removeItem(at: first)
      try? FileManager.default.removeItem(at: second)
    }
    let calendar = utcCalendar()
    let window = try MonthWindow.current(
      containing: isoDate("2026-06-15T00:00:00Z"),
      calendar: calendar
    )
    let catalog = try PriceCatalog.bundled()

    let firstResult = try ClaudeLogScanner(
      sessionRoots: [first, second],
      priceCatalog: catalog,
      calendar: calendar
    ).scan(window: window, fetchedAt: window.end)
    let secondResult = try ClaudeLogScanner(
      sessionRoots: [second, first],
      priceCatalog: catalog,
      calendar: calendar
    ).scan(window: window, fetchedAt: window.end)

    XCTAssertEqual(
      firstResult.records.first?.observationID, secondResult.records.first?.observationID)
  }

  func testScansJuneEventsFromSessionFileModifiedInJuly() throws {
    let root = try fixtureRoot(named: "claude-session")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("claude-session.jsonl")
    try setModificationDate(file, to: isoDate("2026-07-15T00:00:00Z"))
    let calendar = utcCalendar()
    let window = try MonthWindow.current(
      containing: isoDate("2026-06-15T00:00:00Z"),
      calendar: calendar
    )

    let result = try ClaudeLogScanner(
      sessionRoots: [root],
      priceCatalog: try PriceCatalog.bundled(),
      calendar: calendar
    ).scan(window: window, fetchedAt: window.end)

    XCTAssertEqual(result.records.count, 1)
    XCTAssertEqual(result.records.first?.amount, Money(Decimal(string: "5.025")!))
  }

  func testOversizedUnterminatedFinalLineProducesMalformedDiagnostic() throws {
    let root = try emptyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("oversized.jsonl")
    try Data(repeating: 0x78, count: 1_048_577).write(to: file)
    try setModificationDate(file)
    let calendar = utcCalendar()
    let window = try MonthWindow.current(
      containing: isoDate("2026-06-15T00:00:00Z"),
      calendar: calendar
    )

    let result = try ClaudeLogScanner(
      sessionRoots: [root],
      priceCatalog: try PriceCatalog.bundled(),
      calendar: calendar
    ).scan(window: window, fetchedAt: window.end)

    XCTAssertEqual(result.diagnostics, [.malformedLine(file: "oversized.jsonl", line: 1)])
  }
}
