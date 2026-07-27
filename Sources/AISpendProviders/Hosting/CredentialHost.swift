import Foundation
import Security

public enum SourceHostError: Error, Equatable, Sendable {
  case pathNotAllowed
  case domainNotAllowed
  case credentialNotAllowed
  case sourceUnavailable
  case requestFailed(redactedMessage: String)
}

public struct Secret:
  CustomStringConvertible,
  CustomDebugStringConvertible,
  CustomReflectable,
  Sendable
{
  private let value: String

  public init(_ value: String) {
    self.value = value
  }

  public var description: String { "<redacted>" }
  public var debugDescription: String { "<redacted>" }
  public var customMirror: Mirror { Mirror(reflecting: "<redacted>") }

  public func withValue<T>(_ body: (String) throws -> T) rethrows -> T {
    try body(value)
  }
}

public struct KeychainCredential: Hashable, Sendable {
  public let service: String
  public let account: String

  public init(service: String, account: String) {
    self.service = service
    self.account = account
  }
}

public struct CredentialHost {
  public static let allowedEnvironmentNames: Set<String> = [
    "ANTHROPIC_API_KEY",
    "CURSOR_ACCESS_TOKEN",
    "OPENAI_API_KEY",
  ]

  public static let allowedKeychainCredentials: Set<KeychainCredential> = [
    KeychainCredential(service: "Claude Code", account: "credentials"),
    KeychainCredential(service: "Codex", account: "auth"),
    KeychainCredential(service: "Cursor", account: "accessToken"),
  ]

  private let environment: [String: String]
  private let homeDirectory: URL
  private let keychainLookup: (String, String) throws -> Data?

  public init() {
    self.init(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
  }

  init(
    homeDirectory: URL,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    keychainLookup: @escaping (String, String) throws -> Data? = Self.readKeychain
  ) {
    self.homeDirectory = homeDirectory.standardizedFileURL
    self.environment = environment
    self.keychainLookup = keychainLookup
  }

  public func environmentSecret(named name: String) throws -> Secret? {
    guard Self.allowedEnvironmentNames.contains(name) else {
      throw SourceHostError.credentialNotAllowed
    }
    return environment[name].map(Secret.init)
  }

  public func readFile(at url: URL) throws -> Data {
    let requested = url.standardizedFileURL
    guard allowedFileURLs.contains(requested) else {
      throw SourceHostError.pathNotAllowed
    }

    let resolvedHome = homeDirectory.resolvingSymlinksInPath()
    let resolvedRequest = requested.resolvingSymlinksInPath()
    guard resolvedRequest.path.hasPrefix(resolvedHome.path + "/") else {
      throw SourceHostError.pathNotAllowed
    }

    return try Data(contentsOf: resolvedRequest, options: [.mappedIfSafe])
  }

  public func keychainSecret(service: String, account: String) throws -> Secret? {
    let credential = KeychainCredential(service: service, account: account)
    guard Self.allowedKeychainCredentials.contains(credential) else {
      throw SourceHostError.credentialNotAllowed
    }
    guard let data = try keychainLookup(service, account),
      let value = String(data: data, encoding: .utf8)
    else {
      return nil
    }
    return Secret(value)
  }

  private var allowedFileURLs: Set<URL> {
    [
      homeDirectory.appendingPathComponent(".claude/.credentials.json").standardizedFileURL,
      homeDirectory.appendingPathComponent(".codex/auth.json").standardizedFileURL,
      homeDirectory
        .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        .standardizedFileURL,
    ]
  }

  private static func readKeychain(service: String, account: String) throws -> Data? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecMatchLimit as String: kSecMatchLimitOne,
      kSecReturnData as String: true,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess else {
      throw SourceHostError.sourceUnavailable
    }
    return result as? Data
  }
}
