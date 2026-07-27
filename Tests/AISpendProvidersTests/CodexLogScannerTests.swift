import AISpendCore
import Foundation
import XCTest

@testable import AISpendProviders

final class CodexLogScannerTests: XCTestCase {
  func testScansStreamsDeduplicatesAndAggregatesOneRecordPerModelDay() throws {
    let root = try fixtureRoot(named: "codex-session")
    defer { try? FileManager.default.removeItem(at: root) }
    let calendar = utcCalendar()
    let window = try MonthWindow.current(
      containing: isoDate("2026-06-15T00:00:00Z"),
      calendar: calendar
    )
    let scanner = CodexLogScanner(
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
    XCTAssertEqual(record.provider, .openAI)
    XCTAssertEqual(record.quality, .estimated)
    XCTAssertEqual(record.model, "gpt-5.3-codex")
    XCTAssertEqual(record.amount, Money(Decimal(string: "2.835")!))
    XCTAssertEqual(record.estimate?.inputTokens, 800_000)
    XCTAssertEqual(record.estimate?.cachedInputTokens, 200_000)
    XCTAssertEqual(record.estimate?.outputTokens, 100_000)
    XCTAssertEqual(record.estimate?.catalogVersion, "2026-07-27")
    XCTAssertEqual(result.diagnostics.count, 1)
  }

  func testUnknownModelProducesUnavailableDiagnosticAndNoZeroRecord() throws {
    let root = try emptyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("unknown.jsonl")
    try Data(
      """
      {"timestamp":"2026-06-12T10:45:00Z","type":"event_msg","event_id":"unknown-1","payload":{"type":"token_count","model":"future-codex","info":{"last_token_usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":0}}}}

      """.utf8
    ).write(to: file)
    try setModificationDate(file)
    let calendar = utcCalendar()
    let window = try MonthWindow.current(
      containing: isoDate("2026-06-15T00:00:00Z"),
      calendar: calendar
    )

    let result = try CodexLogScanner(
      sessionRoots: [root],
      priceCatalog: try PriceCatalog.bundled(),
      calendar: calendar
    ).scan(window: window, fetchedAt: window.end)

    XCTAssertTrue(result.records.isEmpty)
    XCTAssertEqual(result.diagnostics, [.unavailableEstimate(model: "future-codex")])
  }
}

func fixtureRoot(named fixture: String) throws -> URL {
  let root = try emptyRoot()
  let source = try XCTUnwrap(
    Bundle.module.url(
      forResource: fixture,
      withExtension: "jsonl",
      subdirectory: "Fixtures"
    )
  )
  let destination = root.appendingPathComponent("\(fixture).jsonl")
  try FileManager.default.copyItem(at: source, to: destination)
  try setModificationDate(destination)
  return root
}

func emptyRoot() throws -> URL {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root
}

func setModificationDate(_ url: URL) throws {
  try FileManager.default.setAttributes(
    [.modificationDate: isoDate("2026-06-30T00:00:00Z")],
    ofItemAtPath: url.path
  )
}

func utcCalendar() -> Calendar {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(secondsFromGMT: 0)!
  return calendar
}

func isoDate(_ value: String) -> Date {
  ISO8601DateFormatter().date(from: value)!
}
