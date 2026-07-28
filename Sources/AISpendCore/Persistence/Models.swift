import Foundation
import SwiftData

public enum ProviderRefreshStatus: String, Codable, Sendable {
  case never
  case success
  case failed
}

public struct StoredProviderState: Codable, Equatable, Sendable {
  public let provider: ProviderID
  public var isEnabled: Bool
  public var lastAttemptAt: Date?
  public var lastSuccessfulAt: Date?
  public var refreshStatus: ProviderRefreshStatus
  public var lastFailureMessage: String?

  public init(
    provider: ProviderID,
    isEnabled: Bool,
    lastAttemptAt: Date? = nil,
    lastSuccessfulAt: Date? = nil,
    refreshStatus: ProviderRefreshStatus = .never,
    lastFailureMessage: String? = nil
  ) {
    self.provider = provider
    self.isEnabled = isEnabled
    self.lastAttemptAt = lastAttemptAt
    self.lastSuccessfulAt = lastSuccessfulAt
    self.refreshStatus = refreshStatus
    self.lastFailureMessage = lastFailureMessage
  }
}

public struct StoredBudgetAlertState: Codable, Equatable, Sendable {
  public let budgetID: UUID
  public var lastPacingState: BudgetPacingState?
  public var lastImmediateAlertAt: Date?
  public var lastReminderAt: Date?

  public init(
    budgetID: UUID,
    lastPacingState: BudgetPacingState? = nil,
    lastImmediateAlertAt: Date? = nil,
    lastReminderAt: Date? = nil
  ) {
    self.budgetID = budgetID
    self.lastPacingState = lastPacingState
    self.lastImmediateAlertAt = lastImmediateAlertAt
    self.lastReminderAt = lastReminderAt
  }
}

@Model
public final class SpendRecordEntity {
  @Attribute(.unique) public var recordID: String
  public var providerRawValue: String
  public var accountFingerprint: String
  public var model: String
  public var intervalStart: Date
  public var intervalEnd: Date
  public var amountString: String
  public var currency: String
  public var qualityRawValue: String
  public var sourceID: String
  public var observationID: String
  public var fetchedAt: Date
  public var estimateData: Data?

  public init(
    recordID: String,
    providerRawValue: String,
    accountFingerprint: String,
    model: String,
    intervalStart: Date,
    intervalEnd: Date,
    amountString: String,
    currency: String,
    qualityRawValue: String,
    sourceID: String,
    observationID: String,
    fetchedAt: Date,
    estimateData: Data?
  ) {
    self.recordID = recordID
    self.providerRawValue = providerRawValue
    self.accountFingerprint = accountFingerprint
    self.model = model
    self.intervalStart = intervalStart
    self.intervalEnd = intervalEnd
    self.amountString = amountString
    self.currency = currency
    self.qualityRawValue = qualityRawValue
    self.sourceID = sourceID
    self.observationID = observationID
    self.fetchedAt = fetchedAt
    self.estimateData = estimateData
  }
}

@Model
public final class ProviderStateEntity {
  @Attribute(.unique) public var providerRawValue: String
  public var isEnabled: Bool
  public var lastAttemptAt: Date?
  public var lastSuccessfulAt: Date?
  public var refreshStatusRawValue: String
  public var lastFailureMessage: String?

  public init(
    providerRawValue: String,
    isEnabled: Bool,
    lastAttemptAt: Date?,
    lastSuccessfulAt: Date?,
    refreshStatusRawValue: String,
    lastFailureMessage: String?
  ) {
    self.providerRawValue = providerRawValue
    self.isEnabled = isEnabled
    self.lastAttemptAt = lastAttemptAt
    self.lastSuccessfulAt = lastSuccessfulAt
    self.refreshStatusRawValue = refreshStatusRawValue
    self.lastFailureMessage = lastFailureMessage
  }
}

@Model
public final class BudgetEntity {
  @Attribute(.unique) public var budgetID: UUID
  public var amountString: String
  public var currency: String
  public var isEnabled: Bool
  public var createdAt: Date

  public init(
    budgetID: UUID,
    amountString: String,
    currency: String,
    isEnabled: Bool,
    createdAt: Date
  ) {
    self.budgetID = budgetID
    self.amountString = amountString
    self.currency = currency
    self.isEnabled = isEnabled
    self.createdAt = createdAt
  }
}

@Model
public final class BudgetAlertStateEntity {
  @Attribute(.unique) public var budgetID: UUID
  public var lastPacingStateRawValue: String?
  public var lastImmediateAlertAt: Date?
  public var lastReminderAt: Date?

  public init(
    budgetID: UUID,
    lastPacingStateRawValue: String?,
    lastImmediateAlertAt: Date?,
    lastReminderAt: Date?
  ) {
    self.budgetID = budgetID
    self.lastPacingStateRawValue = lastPacingStateRawValue
    self.lastImmediateAlertAt = lastImmediateAlertAt
    self.lastReminderAt = lastReminderAt
  }
}
