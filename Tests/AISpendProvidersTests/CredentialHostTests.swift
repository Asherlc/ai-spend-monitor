import Foundation
import XCTest

@testable import AISpendProviders

final class CredentialHostTests: XCTestCase {
  func testReadRejectsPathOutsideExactAllowlist() throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let host = CredentialHost(homeDirectory: home)

    XCTAssertThrowsError(try host.readFile(at: home.appendingPathComponent(".claude/other.json"))) {
      XCTAssertEqual($0 as? SourceHostError, .pathNotAllowed)
    }
  }

  func testReadRejectsAllowlistedSymlinkEscapingHome() throws {
    let home = try temporaryDirectory()
    let outside = try temporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: home)
      try? FileManager.default.removeItem(at: outside)
    }
    let credentials = outside.appendingPathComponent("credentials.json")
    try Data("secret".utf8).write(to: credentials)
    try FileManager.default.createDirectory(
      at: home.appendingPathComponent(".claude"),
      withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(
      at: home.appendingPathComponent(".claude/.credentials.json"),
      withDestinationURL: credentials
    )

    XCTAssertThrowsError(
      try CredentialHost(homeDirectory: home)
        .readFile(at: home.appendingPathComponent(".claude/.credentials.json"))
    ) {
      XCTAssertEqual($0 as? SourceHostError, .pathNotAllowed)
    }
  }

  func testKeychainLookupRejectsUnknownExactPairBeforeLookup() throws {
    var lookupCount = 0
    let host = CredentialHost(
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
      keychainLookup: { _, _ in
        lookupCount += 1
        return Data("secret".utf8)
      }
    )

    XCTAssertThrowsError(try host.keychainSecret(service: "OpenAI", account: "other")) {
      XCTAssertEqual($0 as? SourceHostError, .credentialNotAllowed)
    }
    XCTAssertEqual(lookupCount, 0)
  }

  func testSecretNeverPrintsItsValue() throws {
    let host = CredentialHost(
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
      environment: ["OPENAI_API_KEY": "sk-test-ultrasecret"]
    )
    let secret = try XCTUnwrap(host.environmentSecret(named: "OPENAI_API_KEY"))

    XCTAssertEqual(String(describing: secret), "<redacted>")
    XCTAssertEqual(String(reflecting: secret), "<redacted>")
    var dumpOutput = ""
    dump(secret, to: &dumpOutput)
    XCTAssertFalse(dumpOutput.contains("sk-test-ultrasecret"))
    XCTAssertEqual(secret.withValue { $0 }, "sk-test-ultrasecret")
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
