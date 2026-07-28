import Foundation

public struct BudgetDefinition: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
  public var limit: Money
  public var isEnabled: Bool
  public let createdAt: Date

  public init(id: UUID, limit: Money, isEnabled: Bool, createdAt: Date) {
    self.id = id
    self.limit = limit
    self.isEnabled = isEnabled
    self.createdAt = createdAt
  }
}

public enum BudgetPacingState: String, Codable, Sendable {
  case collecting
  case onPace
  case offPace
  case unknown
}
