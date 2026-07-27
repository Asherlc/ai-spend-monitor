import Darwin
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

public struct CredentialHost: Sendable {
  public static let allowedEnvironmentNames: Set<String> = [
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_ADMIN_KEY",
    "CURSOR_ACCESS_TOKEN",
    "OPENAI_API_KEY",
    "OPENAI_ADMIN_KEY",
  ]

  public static let allowedKeychainCredentials: Set<KeychainCredential> = [
    KeychainCredential(service: "Claude Code", account: "credentials"),
    KeychainCredential(service: "Codex", account: "auth"),
    KeychainCredential(service: "Cursor", account: "accessToken"),
  ]

  private let environment: [String: String]
  private let homeDirectory: URL
  private let keychainLookup: @Sendable (String, String) throws -> Data?

  public init() {
    self.init(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
  }

  init(
    homeDirectory: URL,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    keychainLookup: @escaping @Sendable (String, String) throws -> Data? = Self.readKeychain
  ) {
    self.homeDirectory = homeDirectory.standardizedFileURL
    self.environment = environment
    self.keychainLookup = keychainLookup
  }

  func environmentSecret(named name: String) throws -> Secret? {
    guard Self.allowedEnvironmentNames.contains(name) else {
      throw SourceHostError.credentialNotAllowed
    }
    return environment[name].map(Secret.init)
  }

  public func resolve(
    environmentName: String,
    file: URL,
    keychain: KeychainCredential
  ) throws -> Secret? {
    if let secret = try environmentSecret(named: environmentName) {
      return secret
    }
    do {
      let data = try readFile(at: file)
      guard let value = String(data: data, encoding: .utf8) else {
        throw SourceHostError.sourceUnavailable
      }
      return Secret(value)
    } catch SourceHostError.sourceUnavailable {
      return try keychainSecret(service: keychain.service, account: keychain.account)
    }
  }

  func readFile(at url: URL) throws -> Data {
    let requested = url.standardizedFileURL
    guard let components = allowedFileComponents[requested] else {
      throw SourceHostError.pathNotAllowed
    }
    return try SecureFileReader.read(root: homeDirectory, relativeComponents: components)
  }

  func keychainSecret(service: String, account: String) throws -> Secret? {
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

  private var allowedFileComponents: [URL: [String]] {
    let allowed = [
      [".claude", ".credentials.json"],
      [".codex", "auth.json"],
      ["Library", "Application Support", "Cursor", "User", "globalStorage", "state.vscdb"],
    ]
    return Dictionary(
      uniqueKeysWithValues: allowed.map { components in
        (
          components.reduce(homeDirectory) { $0.appendingPathComponent($1) }.standardizedFileURL,
          components
        )
      }
    )
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

enum SecureFileReader {
  static func read(root: URL, relativeComponents: [String]) throws -> Data {
    let descriptor = try openFile(root: root, relativeComponents: relativeComponents)
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
      return try handle.readToEnd() ?? Data()
    } catch {
      throw SourceHostError.sourceUnavailable
    }
  }

  static func openFile(root: URL, relativeComponents: [String]) throws -> Int32 {
    guard !relativeComponents.isEmpty,
      relativeComponents.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else {
      throw SourceHostError.pathNotAllowed
    }

    var currentDescriptor = Darwin.open(
      root.path,
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard currentDescriptor >= 0 else {
      throw openError()
    }

    for component in relativeComponents.dropLast() {
      let nextDescriptor = Darwin.openat(
        currentDescriptor,
        component,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
      )
      let openErrno = errno
      Darwin.close(currentDescriptor)
      guard nextDescriptor >= 0 else {
        throw openError(openErrno)
      }
      currentDescriptor = nextDescriptor
    }

    let fileDescriptor = Darwin.openat(
      currentDescriptor,
      relativeComponents.last!,
      O_RDONLY | O_CLOEXEC | O_NOFOLLOW
    )
    let openErrno = errno
    Darwin.close(currentDescriptor)
    guard fileDescriptor >= 0 else {
      throw openError(openErrno)
    }

    var status = stat()
    guard fstat(fileDescriptor, &status) == 0,
      status.st_mode & S_IFMT == S_IFREG
    else {
      Darwin.close(fileDescriptor)
      throw SourceHostError.pathNotAllowed
    }
    return fileDescriptor
  }

  private static func openError(_ code: Int32 = errno) -> SourceHostError {
    switch code {
    case ELOOP, ENOTDIR:
      return .pathNotAllowed
    default:
      return .sourceUnavailable
    }
  }
}
