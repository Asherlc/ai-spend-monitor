import Foundation

enum FireworksCredential {
  static let keychain = KeychainCredential(
    service: "FireworksAI",
    account: "fireworks-api-key"
  )

  static func resolve(from host: CredentialHost) throws -> Secret? {
    if let environment = try host.environmentSecret(named: "FIREWORKS_API_KEY") {
      return environment
    }
    return try host.keychainSecret(
      service: keychain.service,
      account: keychain.account
    )
  }
}
