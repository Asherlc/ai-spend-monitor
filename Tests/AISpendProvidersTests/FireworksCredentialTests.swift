import Foundation
import XCTest

@testable import AISpendProviders

final class FireworksCredentialTests: XCTestCase {
  func testFireworksCredentialUsesEnvironmentBeforeFireConnectKeychain() throws {
    let invocations = FireworksKeychainInvocationRecorder()
    let host = CredentialHost(
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
      environment: ["FIREWORKS_API_KEY": "fw_environment"],
      keychainLookup: { service, account in
        invocations.record(service: service, account: account)
        return Data("fw_keychain".utf8)
      }
    )

    let secret = try XCTUnwrap(FireworksCredential.resolve(from: host))

    XCTAssertEqual(secret.withValue { $0 }, "fw_environment")
    XCTAssertNil(invocations.credential)
  }

  func testFireworksCredentialFallsBackToFireConnectKeychain() throws {
    let invocations = FireworksKeychainInvocationRecorder()
    let host = CredentialHost(
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
      environment: [:],
      keychainLookup: { service, account in
        invocations.record(service: service, account: account)
        return Data("fw_keychain".utf8)
      }
    )

    let secret = try XCTUnwrap(FireworksCredential.resolve(from: host))

    XCTAssertEqual(secret.withValue { $0 }, "fw_keychain")
    XCTAssertEqual(
      invocations.credential,
      KeychainCredential(service: "FireworksAI", account: "fireworks-api-key")
    )
  }
}

private final class FireworksKeychainInvocationRecorder: @unchecked Sendable {
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
