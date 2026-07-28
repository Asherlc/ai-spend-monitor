public struct FireworksModelIdentity: Hashable, Sendable {
  public let canonicalModel: String
  let isResource: Bool

  public init?(_ rawValue: String) {
    let components = rawValue.split(separator: "/", omittingEmptySubsequences: false)
    guard components.first == "accounts" else {
      canonicalModel = rawValue
      isResource = false
      return
    }
    guard
      components.count >= 4,
      !components[1].isEmpty,
      components[2] == "models" || components[2] == "routers",
      !components[3...].contains(where: \.isEmpty)
    else {
      return nil
    }

    canonicalModel = components[2...].joined(separator: "/")
    isResource = true
  }
}
