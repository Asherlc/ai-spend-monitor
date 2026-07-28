public enum ProviderID: String, Codable, CaseIterable, Sendable {
  case cursor
  case claude
  case openAI = "openai"
  case fireworks
}

public enum SpendQuality: String, Codable, Sendable {
  case actual
  case estimated
}

public struct ProviderDescriptor: Hashable, Sendable {
  public let id: ProviderID
  public let displayName: String

  public init(id: ProviderID, displayName: String) {
    self.id = id
    self.displayName = displayName
  }

  public static let builtIns = [
    ProviderDescriptor(id: .cursor, displayName: "Cursor"),
    ProviderDescriptor(id: .claude, displayName: "Claude"),
    ProviderDescriptor(id: .openAI, displayName: "OpenAI"),
    ProviderDescriptor(id: .fireworks, displayName: "Fireworks"),
  ]
}
