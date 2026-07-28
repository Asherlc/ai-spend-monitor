import Darwin
import Foundation
import SQLite3

public struct CursorState: CustomStringConvertible, CustomDebugStringConvertible, Sendable {
  public let accessToken: Secret?
  public let cachedEmail: Secret?
  public let teamID: Secret?
  public let queriedKeys: Set<String>

  public var description: String { "<redacted>" }
  public var debugDescription: String { "<redacted>" }
}

public struct CursorStateReader: Sendable {
  private static let accessTokenKey = "cursorAuth/accessToken"
  private static let cachedEmailKey = "cursorAuth/cachedEmail"
  private static let teamIDKey = "cursorAuth/teamId"

  private let allowedDatabaseURL: URL
  private let allowedRootURL: URL
  private let relativeComponents: [String]

  public init() {
    let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
    allowedDatabaseURL =
      home
      .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
      .standardizedFileURL
    allowedRootURL = home
    relativeComponents = [
      "Library", "Application Support", "Cursor", "User", "globalStorage", "state.vscdb",
    ]
  }

  init(allowedDatabaseURL: URL) {
    self.allowedDatabaseURL = allowedDatabaseURL.standardizedFileURL
    allowedRootURL = allowedDatabaseURL.deletingLastPathComponent().standardizedFileURL
    relativeComponents = [allowedDatabaseURL.lastPathComponent]
  }

  public func read() throws -> CursorState {
    try read(at: allowedDatabaseURL)
  }

  func read(at url: URL) throws -> CursorState {
    let requested = url.standardizedFileURL
    guard requested == allowedDatabaseURL else {
      throw SourceHostError.pathNotAllowed
    }

    let descriptor = try SecureFileReader.openFile(
      root: allowedRootURL,
      relativeComponents: relativeComponents
    )
    defer { Darwin.close(descriptor) }

    var database: OpaquePointer?
    guard
      sqlite3_open_v2(
        "/dev/fd/\(descriptor)",
        &database,
        SQLITE_OPEN_READONLY,
        nil
      ) == SQLITE_OK
    else {
      if let database {
        sqlite3_close(database)
      }
      throw SourceHostError.sourceUnavailable
    }
    defer { sqlite3_close(database) }

    let keys = [Self.accessTokenKey, Self.cachedEmailKey, Self.teamIDKey]
    var values: [String: Secret] = [:]
    for key in keys {
      if let value = try readValue(for: key, from: database) {
        values[key] = Secret(value)
      }
    }
    return CursorState(
      accessToken: values[Self.accessTokenKey],
      cachedEmail: values[Self.cachedEmailKey],
      teamID: values[Self.teamIDKey],
      queriedKeys: Set(keys)
    )
  }

  private func readValue(for key: String, from database: OpaquePointer?) throws -> String? {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        "SELECT value FROM ItemTable WHERE key = ? LIMIT 1",
        -1,
        &statement,
        nil
      ) == SQLITE_OK
    else {
      throw SourceHostError.sourceUnavailable
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_bind_text(statement, 1, key, -1, sqliteTransient) == SQLITE_OK else {
      throw SourceHostError.sourceUnavailable
    }
    switch sqlite3_step(statement) {
    case SQLITE_ROW:
      guard let bytes = sqlite3_column_text(statement, 0) else {
        return nil
      }
      return String(cString: bytes)
    case SQLITE_DONE:
      return nil
    default:
      throw SourceHostError.sourceUnavailable
    }
  }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
