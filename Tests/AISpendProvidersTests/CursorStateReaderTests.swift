import Foundation
import SQLite3
import XCTest

@testable import AISpendProviders

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class CursorStateReaderTests: XCTestCase {
  func testRejectsSymlinkDirectoryComponentInsideRoot() throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let realDirectory = home.appendingPathComponent("real-cursor")
    try FileManager.default.createDirectory(
      at: realDirectory,
      withIntermediateDirectories: true
    )
    let realDatabase = realDirectory.appendingPathComponent("state.vscdb")
    try makeDatabase(at: realDatabase, values: [:])
    let linkedDirectory = home.appendingPathComponent("linked-cursor")
    try FileManager.default.createSymbolicLink(
      at: linkedDirectory,
      withDestinationURL: realDirectory
    )
    let allowedDatabase = linkedDirectory.appendingPathComponent("state.vscdb")

    XCTAssertThrowsError(
      try CursorStateReader(allowedDatabaseURL: allowedDatabase).read(at: allowedDatabase)
    ) {
      XCTAssertEqual($0 as? SourceHostError, .pathNotAllowed)
    }
  }

  func testRejectsAllowlistedSymlinkToDifferentDatabaseInsideRoot() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let differentDatabase = root.appendingPathComponent("different.vscdb")
    try makeDatabase(at: differentDatabase, values: [:])
    let allowedDatabase = root.appendingPathComponent("state.vscdb")
    try FileManager.default.createSymbolicLink(
      at: allowedDatabase,
      withDestinationURL: differentDatabase
    )

    XCTAssertThrowsError(
      try CursorStateReader(allowedDatabaseURL: allowedDatabase).read(at: allowedDatabase)
    ) {
      XCTAssertEqual($0 as? SourceHostError, .pathNotAllowed)
    }
  }

  func testRejectsAllowlistedSymlinkEscapingItsRoot() throws {
    let root = try temporaryDirectory()
    let outside = try temporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: outside)
    }
    let outsideDatabase = outside.appendingPathComponent("state.vscdb")
    try makeDatabase(at: outsideDatabase, values: [:])
    let allowedDatabase = root.appendingPathComponent("state.vscdb")
    try FileManager.default.createSymbolicLink(
      at: allowedDatabase,
      withDestinationURL: outsideDatabase
    )

    XCTAssertThrowsError(
      try CursorStateReader(allowedDatabaseURL: allowedDatabase).read(at: allowedDatabase)
    ) {
      XCTAssertEqual($0 as? SourceHostError, .pathNotAllowed)
    }
  }

  func testReadsOnlyRequiredKeysAndSecretsAreNotPrintable() throws {
    let fixtureURL = Bundle.module.url(
      forResource: "cursor-state",
      withExtension: "json",
      subdirectory: "Fixtures"
    )!
    let fixture =
      try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL))
      as! [String: String]
    let databaseURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(UUID().uuidString).vscdb")
    defer { try? FileManager.default.removeItem(at: databaseURL) }
    try makeDatabase(
      at: databaseURL, values: fixture.merging(["unrelated": "must-not-read"]) { $1 })

    let state = try CursorStateReader(allowedDatabaseURL: databaseURL).read(at: databaseURL)

    XCTAssertEqual(state.accessToken?.withValue { $0 }, "cursor-access-secret")
    XCTAssertEqual(state.cachedEmail?.withValue { $0 }, "cursor@example.com")
    XCTAssertEqual(state.teamID?.withValue { $0 }, "team-secret-id")
    XCTAssertFalse(String(reflecting: state).contains("cursor-access-secret"))
    XCTAssertFalse(String(reflecting: state).contains("cursor@example.com"))
    XCTAssertFalse(String(reflecting: state).contains("team-secret-id"))
    XCTAssertEqual(state.queriedKeys.count, 3)
    XCTAssertFalse(state.queriedKeys.contains("unrelated"))
  }

  private func makeDatabase(at url: URL, values: [String: String]) throws {
    var database: OpaquePointer?
    XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
    defer { sqlite3_close(database) }
    XCTAssertEqual(
      sqlite3_exec(
        database,
        "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT)",
        nil,
        nil,
        nil
      ),
      SQLITE_OK
    )
    for (key, value) in values {
      var statement: OpaquePointer?
      XCTAssertEqual(
        sqlite3_prepare_v2(
          database,
          "INSERT INTO ItemTable (key, value) VALUES (?, ?)",
          -1,
          &statement,
          nil
        ),
        SQLITE_OK
      )
      defer { sqlite3_finalize(statement) }
      sqlite3_bind_text(statement, 1, key, -1, sqliteTransient)
      sqlite3_bind_text(statement, 2, value, -1, sqliteTransient)
      XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    }
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
