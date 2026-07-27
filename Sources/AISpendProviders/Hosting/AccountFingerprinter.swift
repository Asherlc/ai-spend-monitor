import CryptoKit
import Foundation
import Security

public struct AccountFingerprinter: Sendable {
  private let operation: @Sendable (Secret, String) throws -> String

  public init(
    operation: @escaping @Sendable (Secret, String) throws -> String
  ) {
    self.operation = operation
  }

  public init(key: Data) {
    let symmetricKey = SymmetricKey(data: key)
    self.init { identity, namespace in
      identity.withValue { value in
        keyedIdentifier(
          [namespace, value],
          key: symmetricKey
        )
      }
    }
  }

  public func fingerprint(
    identity: Secret,
    namespace: String
  ) throws -> String {
    try operation(identity, namespace)
  }

  public static let production = AccountFingerprinter { identity, namespace in
    let key = try AccountFingerprintKeyStore.shared.key()
    return identity.withValue { value in
      keyedIdentifier([namespace, value], key: key)
    }
  }
}

private func keyedIdentifier(
  _ components: [String],
  key: SymmetricKey
) -> String {
  let data = Data(components.joined(separator: "\u{1f}").utf8)
  return HMAC<SHA256>.authenticationCode(for: data, using: key)
    .map { String(format: "%02x", $0) }
    .joined()
}

func stableIdentifier(_ components: [String]) -> String {
  let data = Data(components.joined(separator: "\u{1f}").utf8)
  return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private final class AccountFingerprintKeyStore: @unchecked Sendable {
  static let shared = AccountFingerprintKeyStore()

  private static let service =
    "com.ashercohen.AISpendBar.account-fingerprint"
  private static let account = "hmac-key-v1"
  private static let keyLength = 32

  private let lock = NSLock()
  private var cachedKey: SymmetricKey?

  func key() throws -> SymmetricKey {
    try lock.withLock {
      if let cachedKey {
        return cachedKey
      }
      let data = try loadOrCreateKey()
      let key = SymmetricKey(data: data)
      cachedKey = key
      return key
    }
  }

  private func loadOrCreateKey() throws -> Data {
    if let existing = try readKey() {
      guard existing.count == Self.keyLength else {
        throw AccountFingerprintKeyError.invalidStoredKey
      }
      return existing
    }

    var bytes = [UInt8](repeating: 0, count: Self.keyLength)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess
    else {
      throw AccountFingerprintKeyError.randomGenerationFailed
    }
    let generated = Data(bytes)
    let attributes: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: Self.service,
      kSecAttrAccount: Self.account,
      kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      kSecValueData: generated,
    ]
    let status = SecItemAdd(attributes as CFDictionary, nil)
    if status == errSecSuccess {
      return generated
    }
    if status == errSecDuplicateItem, let existing = try readKey() {
      guard existing.count == Self.keyLength else {
        throw AccountFingerprintKeyError.invalidStoredKey
      }
      return existing
    }
    throw AccountFingerprintKeyError.keychainFailure(status)
  }

  private func readKey() throws -> Data? {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: Self.service,
      kSecAttrAccount: Self.account,
      kSecMatchLimit: kSecMatchLimitOne,
      kSecReturnData: true,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess, let data = result as? Data else {
      throw AccountFingerprintKeyError.keychainFailure(status)
    }
    return data
  }
}

private enum AccountFingerprintKeyError: Error {
  case invalidStoredKey
  case randomGenerationFailed
  case keychainFailure(OSStatus)
}
