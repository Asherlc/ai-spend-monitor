import CryptoKit
import Foundation

public struct AccountFingerprinter: Sendable {
  private let operation: @Sendable (Secret, String) -> String

  public init(operation: @escaping @Sendable (Secret, String) -> String) {
    self.operation = operation
  }

  public func fingerprint(identity: Secret, namespace: String) -> String {
    operation(identity, namespace)
  }

  public static let production = AccountFingerprinter { identity, namespace in
    identity.withValue { value in
      stableIdentifier([namespace, value])
    }
  }
}

func stableIdentifier(_ components: [String]) -> String {
  let data = Data(components.joined(separator: "\u{1f}").utf8)
  return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
