import AISpendCore
import Foundation
import XCTest

@testable import AISpendProviders

final class CursorCSVScannerTests: XCTestCase {
  func testScansLatestDashboardExportAsActualSpendByModelAndDay() throws {
    let downloads = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: downloads) }
    let export = downloads.appendingPathComponent(
      "team-usage-events-5776093-2026-07-28.csv"
    )
    try Data(
      """
      Date,User,Cloud Agent ID,Automation ID,Kind,Model,Max Mode,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Total Tokens,Cost
      2026-07-24T22:58:47.622Z,user@example.com,,,Included,"Opus 4.8, Auto",false,1,2,3,4,10,0.72
      2026-07-24T22:58:48.622Z,user@example.com,,,Included,"Opus 4.8, Auto",false,1,2,3,4,10,1.32
      2026-07-25T01:00:00.001Z,user@example.com,,,Included,GPT-5.6 Sol,false,1,2,3,4,10,2.50
      2026-07-25T02:00:00.001Z,user@example.com,,,Free,Composer,false,1,2,3,4,10,Free
      2026-08-01T02:00:00.001Z,user@example.com,,,Included,Outside,false,1,2,3,4,10,9.99
      """.utf8
    ).write(to: export)

    let result = try CursorCSVScanner(
      downloadsDirectory: downloads,
      fingerprinter: AccountFingerprinter(key: Data(repeating: 1, count: 32))
    ).scan(
      window: julyWindow(),
      fetchedAt: julyDate()
    )

    XCTAssertEqual(result?.records.count, 2)
    XCTAssertEqual(
      Dictionary(
        uniqueKeysWithValues: try XCTUnwrap(result).records.map {
          ($0.model, $0.amount.amount)
        }),
      [
        "Opus 4.8, Auto": Decimal(string: "2.04")!,
        "GPT-5.6 Sol": Decimal(string: "2.50")!,
      ]
    )
    XCTAssertTrue(try XCTUnwrap(result).records.allSatisfy { $0.quality == .actual })
    XCTAssertEqual(result?.sourceID, "cursor-dashboard-export")
  }

  func testReturnsNilWithoutARegularDashboardExport() throws {
    let downloads = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: downloads) }
    let outside = downloads.appendingPathComponent("outside.csv")
    try Data("Date,Model,Cost\n".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(
      at: downloads.appendingPathComponent("team-usage-events-1-2026-07-28.csv"),
      withDestinationURL: outside
    )

    XCTAssertNil(
      try CursorCSVScanner(
        downloadsDirectory: downloads,
        fingerprinter: AccountFingerprinter(key: Data(repeating: 1, count: 32))
      ).scan(
        window: julyWindow(),
        fetchedAt: julyDate()
      )
    )
  }
}
