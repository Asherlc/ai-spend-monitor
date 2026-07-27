import Foundation
import XCTest

@testable import AISpendProviders

final class CredentialHostTests: XCTestCase {
  func testCredentialHostIsSendable() {
    assertSendable(CredentialHost())
  }

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

  func testReadRejectsAllowlistedSymlinkToDifferentFileInsideHome() throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let differentFile = home.appendingPathComponent("different.json")
    try Data("wrong-secret".utf8).write(to: differentFile)
    try FileManager.default.createDirectory(
      at: home.appendingPathComponent(".claude"),
      withIntermediateDirectories: true
    )
    let allowedFile = home.appendingPathComponent(".claude/.credentials.json")
    try FileManager.default.createSymbolicLink(
      at: allowedFile,
      withDestinationURL: differentFile
    )

    XCTAssertThrowsError(try CredentialHost(homeDirectory: home).readFile(at: allowedFile)) {
      XCTAssertEqual($0 as? SourceHostError, .pathNotAllowed)
    }
  }

  func testReadRejectsSymlinkDirectoryComponentInsideHome() throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let realDirectory = home.appendingPathComponent("real-claude")
    try FileManager.default.createDirectory(
      at: realDirectory,
      withIntermediateDirectories: true
    )
    try Data("wrong-secret".utf8).write(
      to: realDirectory.appendingPathComponent(".credentials.json")
    )
    try FileManager.default.createSymbolicLink(
      at: home.appendingPathComponent(".claude"),
      withDestinationURL: realDirectory
    )

    XCTAssertThrowsError(
      try CredentialHost(homeDirectory: home)
        .readFile(at: home.appendingPathComponent(".claude/.credentials.json"))
    ) {
      XCTAssertEqual($0 as? SourceHostError, .pathNotAllowed)
    }
  }

  func testReadAcceptsAllowlistedRegularFile() throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let allowedFile = home.appendingPathComponent(".claude/.credentials.json")
    try FileManager.default.createDirectory(
      at: allowedFile.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("regular-secret".utf8).write(to: allowedFile)

    let data = try CredentialHost(homeDirectory: home).readFile(at: allowedFile)

    XCTAssertEqual(String(decoding: data, as: UTF8.self), "regular-secret")
  }

  func testKeychainLookupRejectsUnknownExactPairBeforeLookup() throws {
    let lookupCount = LockedCounter()
    let host = CredentialHost(
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
      keychainLookup: { _, _ in
        lookupCount.increment()
        return Data("secret".utf8)
      }
    )

    XCTAssertThrowsError(try host.keychainSecret(service: "OpenAI", account: "other")) {
      XCTAssertEqual($0 as? SourceHostError, .credentialNotAllowed)
    }
    XCTAssertEqual(lookupCount.value, 0)
  }

  func testKeychainLookupForwardsAllowedExactPair() throws {
    let invocation = KeychainInvocationRecorder()
    let expected = KeychainCredential(service: "Cursor", account: "accessToken")
    let host = CredentialHost(
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
      keychainLookup: { service, account in
        invocation.record(service: service, account: account)
        return Data("keychain-secret".utf8)
      }
    )

    let secret = try XCTUnwrap(
      host.keychainSecret(service: expected.service, account: expected.account)
    )

    XCTAssertEqual(invocation.credential, expected)
    XCTAssertEqual(secret.withValue { $0 }, "keychain-secret")
  }

  func testResolveUsesEnvironmentBeforeFileAndKeychain() throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let lookupCount = LockedCounter()
    let host = CredentialHost(
      homeDirectory: home,
      environment: ["OPENAI_API_KEY": "environment-secret"],
      keychainLookup: { _, _ in
        lookupCount.increment()
        return Data("keychain-secret".utf8)
      }
    )

    let secret = try XCTUnwrap(
      host.resolve(
        environmentName: "OPENAI_API_KEY",
        file: home.appendingPathComponent(".codex/auth.json"),
        keychain: KeychainCredential(service: "Codex", account: "auth")
      )
    )

    XCTAssertEqual(secret.withValue { $0 }, "environment-secret")
    XCTAssertEqual(lookupCount.value, 0)
  }

  func testResolveUsesFileBeforeKeychain() throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let allowedFile = home.appendingPathComponent(".codex/auth.json")
    try FileManager.default.createDirectory(
      at: allowedFile.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("file-secret".utf8).write(to: allowedFile)
    let lookupCount = LockedCounter()
    let host = CredentialHost(
      homeDirectory: home,
      environment: [:],
      keychainLookup: { _, _ in
        lookupCount.increment()
        return Data("keychain-secret".utf8)
      }
    )

    let secret = try XCTUnwrap(
      host.resolve(
        environmentName: "OPENAI_API_KEY",
        file: allowedFile,
        keychain: KeychainCredential(service: "Codex", account: "auth")
      )
    )

    XCTAssertEqual(secret.withValue { $0 }, "file-secret")
    XCTAssertEqual(lookupCount.value, 0)
  }

  func testResolveFallsBackToKeychainWhenEnvironmentAndFileAreUnavailable() throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let invocation = KeychainInvocationRecorder()
    let credential = KeychainCredential(service: "Codex", account: "auth")
    let host = CredentialHost(
      homeDirectory: home,
      environment: [:],
      keychainLookup: { service, account in
        invocation.record(service: service, account: account)
        return Data("keychain-secret".utf8)
      }
    )

    let secret = try XCTUnwrap(
      host.resolve(
        environmentName: "OPENAI_API_KEY",
        file: home.appendingPathComponent(".codex/auth.json"),
        keychain: credential
      )
    )

    XCTAssertEqual(secret.withValue { $0 }, "keychain-secret")
    XCTAssertEqual(invocation.credential, credential)
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

private func assertSendable<T: Sendable>(_ value: T) {}

private final class LockedCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int {
    lock.withLock { count }
  }

  func increment() {
    lock.withLock { count += 1 }
  }
}

private final class KeychainInvocationRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedCredential: KeychainCredential?

  var credential: KeychainCredential? {
    lock.withLock { storedCredential }
  }

  func record(service: String, account: String) {
    lock.withLock {
      storedCredential = KeychainCredential(service: service, account: account)
    }
  }
}
