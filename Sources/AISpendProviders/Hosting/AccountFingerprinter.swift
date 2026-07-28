import AISpendCore
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
    let key = SymmetricKey(data: try AccountFingerprintKeyStore.shared.keyData())
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

final class AccountFingerprintKeyStore: @unchecked Sendable {
  static let shared = AccountFingerprintKeyStore(
    fileURL: AppStorageLocation.defaultLedgerURL
      .deletingLastPathComponent()
      .appendingPathComponent("account-fingerprint-key-v1")
  )

  private static let keyLength = 32

  private let fileURL: URL
  private let randomData: @Sendable () throws -> Data
  private let lock = NSLock()
  private var cachedData: Data?

  init(
    fileURL: URL,
    randomData: @escaping @Sendable () throws -> Data =
      AccountFingerprintKeyStore.generateRandomData
  ) {
    self.fileURL = fileURL
    self.randomData = randomData
  }

  func keyData() throws -> Data {
    try lock.withLock {
      if let cachedData {
        return cachedData
      }
      let data = try loadOrCreateData()
      cachedData = data
      return data
    }
  }

  private func loadOrCreateData() throws -> Data {
    if FileManager.default.fileExists(atPath: fileURL.path) {
      return try validated(Data(contentsOf: fileURL))
    }

    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    let generated = try validated(randomData())
    let attributes: [FileAttributeKey: Any] = [
      .posixPermissions: NSNumber(value: 0o600)
    ]
    if FileManager.default.createFile(
      atPath: fileURL.path,
      contents: generated,
      attributes: attributes
    ) {
      return generated
    }
    return try validated(Data(contentsOf: fileURL))
  }

  private func validated(_ data: Data) throws -> Data {
    guard data.count == Self.keyLength else {
      throw AccountFingerprintKeyError.invalidStoredKey
    }
    return data
  }

  private static func generateRandomData() throws -> Data {
    var bytes = [UInt8](repeating: 0, count: keyLength)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess
    else {
      throw AccountFingerprintKeyError.randomGenerationFailed
    }
    return Data(bytes)
  }
}

enum AccountFingerprintKeyError: Error {
  case invalidStoredKey
  case randomGenerationFailed
}
