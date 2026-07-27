import Foundation
import XCTest

@testable import AISpendProviders

final class AccountFingerprinterTests: XCTestCase {
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
