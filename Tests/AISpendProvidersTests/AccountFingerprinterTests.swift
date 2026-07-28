import Foundation
import XCTest

@testable import AISpendProviders

final class AccountFingerprinterTests: XCTestCase {
  func testFingerprintKeyPersistsInPrivateAppStorageWithoutCredentialAccess() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let keyURL = directory.appendingPathComponent("fingerprint-key")
    defer { try? FileManager.default.removeItem(at: directory) }

    let firstStore = AccountFingerprintKeyStore(
      fileURL: keyURL,
      randomData: { Data(repeating: 0x44, count: 32) }
    )
    let first = try firstStore.keyData()
    let relaunched = try AccountFingerprintKeyStore(
      fileURL: keyURL,
      randomData: { Data(repeating: 0x55, count: 32) }
    ).keyData()
    let attributes = try FileManager.default.attributesOfItem(atPath: keyURL.path)

    XCTAssertEqual(first, Data(repeating: 0x44, count: 32))
    XCTAssertEqual(relaunched, first)
    XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))
  }

  func testKeyedFingerprintIsStableForSameKeyAndChangesForDifferentKey() throws {
    let identity = Secret("/Users/example/.claude")
    let first = AccountFingerprinter(key: Data(repeating: 0x11, count: 32))
    let relaunched = AccountFingerprinter(key: Data(repeating: 0x11, count: 32))
    let otherInstall = AccountFingerprinter(key: Data(repeating: 0x22, count: 32))

    let firstValue = try first.fingerprint(
      identity: identity,
      namespace: "claude-account"
    )
    let relaunchedValue = try relaunched.fingerprint(
      identity: identity,
      namespace: "claude-account"
    )
    let otherInstallValue = try otherInstall.fingerprint(
      identity: identity,
      namespace: "claude-account"
    )

    XCTAssertEqual(firstValue, relaunchedValue)
    XCTAssertNotEqual(firstValue, otherInstallValue)
    XCTAssertFalse(firstValue.contains("/Users/example"))
    XCTAssertFalse(firstValue.contains("claude"))
    XCTAssertEqual(firstValue.count, 64)
  }

  func testNamespacesCannotShareFingerprintForSameIdentity() throws {
    let fingerprinter = AccountFingerprinter(key: Data(repeating: 0x33, count: 32))
    let identity = Secret("same-private-identity")

    let claude = try fingerprinter.fingerprint(
      identity: identity,
      namespace: "claude-account"
    )
    let openAI = try fingerprinter.fingerprint(
      identity: identity,
      namespace: "openai-account"
    )

    XCTAssertNotEqual(claude, openAI)
    XCTAssertFalse(claude.contains("same-private-identity"))
    XCTAssertFalse(openAI.contains("same-private-identity"))
  }
}
