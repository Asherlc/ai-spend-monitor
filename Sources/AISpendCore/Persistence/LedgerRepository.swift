import Foundation
import SwiftData

public enum LedgerError: Error, Equatable {
  case corruptedData
  case duplicateBudget
  case invalidBudget
  case invalidRecord
  case budgetNotFound
}

@MainActor
public protocol LedgerRepository: AnyObject {
  func records(in window: MonthWindow) throws -> [SpendRecord]
  func replace(
    records: [SpendRecord],
    provider: ProviderID,
    sourceID: String,
    interval: MonthWindow
  ) throws
  func providerStates() throws -> [ProviderID: StoredProviderState]
  func saveProviderState(_ state: StoredProviderState) throws
  func budgets() throws -> [BudgetDefinition]
  func addBudget(limit: Money, now: Date) throws -> BudgetDefinition
  func updateBudget(_ budget: BudgetDefinition) throws
  func removeBudget(id: UUID) throws
  func alertState(for budgetID: UUID) throws -> StoredBudgetAlertState
  func saveAlertState(_ state: StoredBudgetAlertState) throws
}

@MainActor
public final class SwiftDataLedgerRepository: LedgerRepository {
  private let context: ModelContext
  private let saveContext: (ModelContext) throws -> Void
  private let jsonEncoder = JSONEncoder()
  private let jsonDecoder = JSONDecoder()

  public init(modelContainer: ModelContainer) {
    context = ModelContext(modelContainer)
    saveContext = { try $0.save() }
  }

  init(
    modelContainer: ModelContainer,
    saveContext: @escaping (ModelContext) throws -> Void
  ) {
    context = ModelContext(modelContainer)
    self.saveContext = saveContext
  }

  public func records(in window: MonthWindow) throws -> [SpendRecord] {
    let start = window.start
    let end = window.end
    let descriptor = FetchDescriptor<SpendRecordEntity>(
      predicate: #Predicate {
        $0.intervalStart >= start && $0.intervalStart < end
      }
    )
    return try context.fetch(descriptor)
      .map(decodeRecord)
      .sorted(by: recordSort)
  }

  public func replace(
    records: [SpendRecord],
    provider: ProviderID,
    sourceID: String,
    interval: MonthWindow
  ) throws {
    guard interval.end > interval.start, !sourceID.isEmpty else {
      throw LedgerError.invalidRecord
    }

    var seenIDs = Set<String>()
    let replacements = try records.map { record in
      guard
        record.provider == provider,
        record.sourceID == sourceID,
        record.intervalStart >= interval.start,
        record.intervalEnd <= interval.end,
        seenIDs.insert(record.id).inserted
      else {
        throw LedgerError.invalidRecord
      }
      return try encodeRecord(record)
    }

    let providerRawValue = provider.rawValue
    let start = interval.start
    let end = interval.end
    let descriptor = FetchDescriptor<SpendRecordEntity>(
      predicate: #Predicate {
        $0.providerRawValue == providerRawValue
          && $0.sourceID == sourceID
          && $0.intervalStart >= start
          && $0.intervalStart < end
      }
    )
    let existing = try context.fetch(descriptor)
    let replacementIDs = Set(replacements.map(\.recordID))
    let collisions = try context.fetch(FetchDescriptor<SpendRecordEntity>())
      .filter { replacementIDs.contains($0.recordID) }
    guard
      collisions.allSatisfy({
        $0.providerRawValue == providerRawValue
          && $0.sourceID == sourceID
          && $0.intervalStart >= start
          && $0.intervalStart < end
      })
    else {
      throw LedgerError.invalidRecord
    }

    do {
      for entity in existing {
        context.delete(entity)
      }
      for replacement in replacements {
        context.insert(replacement)
      }
      try saveContext(context)
    } catch {
      context.rollback()
      throw error
    }
  }

  public func providerStates() throws -> [ProviderID: StoredProviderState] {
    let entities = try context.fetch(FetchDescriptor<ProviderStateEntity>())
    var result: [ProviderID: StoredProviderState] = [:]
    for entity in entities {
      guard
        let provider = ProviderID(rawValue: entity.providerRawValue),
        let refreshStatus = ProviderRefreshStatus(
          rawValue: entity.refreshStatusRawValue
        )
      else {
        throw LedgerError.corruptedData
      }
      result[provider] = StoredProviderState(
        provider: provider,
        isEnabled: entity.isEnabled,
        lastAttemptAt: entity.lastAttemptAt,
        lastSuccessfulAt: entity.lastSuccessfulAt,
        refreshStatus: refreshStatus,
        lastFailureMessage: entity.lastFailureMessage
      )
    }
    return result
  }

  public func saveProviderState(_ state: StoredProviderState) throws {
    let providerRawValue = state.provider.rawValue
    let descriptor = FetchDescriptor<ProviderStateEntity>(
      predicate: #Predicate { $0.providerRawValue == providerRawValue }
    )
    if let entity = try context.fetch(descriptor).first {
      entity.isEnabled = state.isEnabled
      entity.lastAttemptAt = state.lastAttemptAt
      entity.lastSuccessfulAt = state.lastSuccessfulAt
      entity.refreshStatusRawValue = state.refreshStatus.rawValue
      entity.lastFailureMessage = state.lastFailureMessage
    } else {
      context.insert(
        ProviderStateEntity(
          providerRawValue: providerRawValue,
          isEnabled: state.isEnabled,
          lastAttemptAt: state.lastAttemptAt,
          lastSuccessfulAt: state.lastSuccessfulAt,
          refreshStatusRawValue: state.refreshStatus.rawValue,
          lastFailureMessage: state.lastFailureMessage
        )
      )
    }
    try context.save()
  }

  public func budgets() throws -> [BudgetDefinition] {
    try context.fetch(FetchDescriptor<BudgetEntity>())
      .map(decodeBudget)
      .sorted {
        if $0.createdAt != $1.createdAt {
          return $0.createdAt < $1.createdAt
        }
        return $0.id.uuidString < $1.id.uuidString
      }
  }

  public func addBudget(
    limit: Money,
    now: Date
  ) throws -> BudgetDefinition {
    try validateBudgetLimit(limit)
    try ensureUniqueBudgetLimit(limit, excluding: nil)
    let budget = BudgetDefinition(
      id: UUID(),
      limit: limit,
      isEnabled: true,
      createdAt: now
    )
    context.insert(encodeBudget(budget))
    try context.save()
    return budget
  }

  public func updateBudget(_ budget: BudgetDefinition) throws {
    try validateBudgetLimit(budget.limit)
    try ensureUniqueBudgetLimit(budget.limit, excluding: budget.id)
    let budgetID = budget.id
    let descriptor = FetchDescriptor<BudgetEntity>(
      predicate: #Predicate { $0.budgetID == budgetID }
    )
    guard let entity = try context.fetch(descriptor).first else {
      throw LedgerError.budgetNotFound
    }
    entity.amountString = canonicalDecimalString(budget.limit.amount)
    entity.currency = budget.limit.currency
    entity.isEnabled = budget.isEnabled
    entity.createdAt = budget.createdAt
    try context.save()
  }

  public func removeBudget(id: UUID) throws {
    let budgetID = id
    let budgetDescriptor = FetchDescriptor<BudgetEntity>(
      predicate: #Predicate { $0.budgetID == budgetID }
    )
    guard let budget = try context.fetch(budgetDescriptor).first else {
      throw LedgerError.budgetNotFound
    }
    context.delete(budget)

    let alertDescriptor = FetchDescriptor<BudgetAlertStateEntity>(
      predicate: #Predicate { $0.budgetID == budgetID }
    )
    for alert in try context.fetch(alertDescriptor) {
      context.delete(alert)
    }
    try context.save()
  }

  public func alertState(
    for budgetID: UUID
  ) throws -> StoredBudgetAlertState {
    let id = budgetID
    let descriptor = FetchDescriptor<BudgetAlertStateEntity>(
      predicate: #Predicate { $0.budgetID == id }
    )
    guard let entity = try context.fetch(descriptor).first else {
      return StoredBudgetAlertState(budgetID: budgetID)
    }

    let pacingState: BudgetPacingState?
    if let rawValue = entity.lastPacingStateRawValue {
      guard let decoded = BudgetPacingState(rawValue: rawValue) else {
        throw LedgerError.corruptedData
      }
      pacingState = decoded
    } else {
      pacingState = nil
    }
    return StoredBudgetAlertState(
      budgetID: entity.budgetID,
      lastPacingState: pacingState,
      lastImmediateAlertAt: entity.lastImmediateAlertAt,
      lastReminderAt: entity.lastReminderAt
    )
  }

  public func saveAlertState(_ state: StoredBudgetAlertState) throws {
    let budgetID = state.budgetID
    let descriptor = FetchDescriptor<BudgetAlertStateEntity>(
      predicate: #Predicate { $0.budgetID == budgetID }
    )
    if let entity = try context.fetch(descriptor).first {
      entity.lastPacingStateRawValue = state.lastPacingState?.rawValue
      entity.lastImmediateAlertAt = state.lastImmediateAlertAt
      entity.lastReminderAt = state.lastReminderAt
    } else {
      context.insert(
        BudgetAlertStateEntity(
          budgetID: state.budgetID,
          lastPacingStateRawValue: state.lastPacingState?.rawValue,
          lastImmediateAlertAt: state.lastImmediateAlertAt,
          lastReminderAt: state.lastReminderAt
        )
      )
    }
    try context.save()
  }

  private func encodeRecord(
    _ record: SpendRecord
  ) throws -> SpendRecordEntity {
    let estimateData = try record.estimate.map(jsonEncoder.encode)
    return SpendRecordEntity(
      recordID: record.id,
      providerRawValue: record.provider.rawValue,
      accountFingerprint: record.accountFingerprint,
      model: record.model,
      intervalStart: record.intervalStart,
      intervalEnd: record.intervalEnd,
      amountString: canonicalDecimalString(record.amount.amount),
      currency: record.amount.currency,
      qualityRawValue: record.quality.rawValue,
      sourceID: record.sourceID,
      observationID: record.observationID,
      fetchedAt: record.fetchedAt,
      estimateData: estimateData
    )
  }

  private func decodeRecord(
    _ entity: SpendRecordEntity
  ) throws -> SpendRecord {
    guard
      let provider = ProviderID(rawValue: entity.providerRawValue),
      let quality = SpendQuality(rawValue: entity.qualityRawValue),
      let amount = parseDecimal(entity.amountString)
    else {
      throw LedgerError.corruptedData
    }
    do {
      let estimate = try entity.estimateData.map {
        try jsonDecoder.decode(EstimateMetadata.self, from: $0)
      }
      return try SpendRecord(
        id: entity.recordID,
        provider: provider,
        accountFingerprint: entity.accountFingerprint,
        model: entity.model,
        intervalStart: entity.intervalStart,
        intervalEnd: entity.intervalEnd,
        amount: Money(amount, currency: entity.currency),
        quality: quality,
        sourceID: entity.sourceID,
        observationID: entity.observationID,
        fetchedAt: entity.fetchedAt,
        estimate: estimate
      )
    } catch {
      throw LedgerError.corruptedData
    }
  }

  private func encodeBudget(_ budget: BudgetDefinition) -> BudgetEntity {
    BudgetEntity(
      budgetID: budget.id,
      amountString: canonicalDecimalString(budget.limit.amount),
      currency: budget.limit.currency,
      isEnabled: budget.isEnabled,
      createdAt: budget.createdAt
    )
  }

  private func decodeBudget(
    _ entity: BudgetEntity
  ) throws -> BudgetDefinition {
    guard
      entity.currency == "USD",
      let amount = parseDecimal(entity.amountString),
      amount > 0
    else {
      throw LedgerError.corruptedData
    }
    return BudgetDefinition(
      id: entity.budgetID,
      limit: Money(amount, currency: entity.currency),
      isEnabled: entity.isEnabled,
      createdAt: entity.createdAt
    )
  }

  private func validateBudgetLimit(_ limit: Money) throws {
    guard limit.currency == "USD", limit.amount > 0 else {
      throw LedgerError.invalidBudget
    }
  }

  private func ensureUniqueBudgetLimit(
    _ limit: Money,
    excluding excludedID: UUID?
  ) throws {
    for entity in try context.fetch(FetchDescriptor<BudgetEntity>())
    where entity.budgetID != excludedID {
      guard
        entity.currency == "USD",
        let amount = parseDecimal(entity.amountString)
      else {
        throw LedgerError.corruptedData
      }
      if amount == limit.amount {
        throw LedgerError.duplicateBudget
      }
    }
  }

  private func canonicalDecimalString(_ amount: Decimal) -> String {
    NSDecimalNumber(decimal: amount).stringValue
  }

  private func parseDecimal(_ value: String) -> Decimal? {
    guard
      let amount = Decimal(
        string: value,
        locale: Locale(identifier: "en_US_POSIX")
      ),
      canonicalDecimalString(amount) == value
    else {
      return nil
    }
    return amount
  }

  private func recordSort(_ lhs: SpendRecord, _ rhs: SpendRecord) -> Bool {
    if lhs.intervalStart != rhs.intervalStart {
      return lhs.intervalStart < rhs.intervalStart
    }
    if lhs.provider.rawValue != rhs.provider.rawValue {
      return lhs.provider.rawValue < rhs.provider.rawValue
    }
    if lhs.sourceID != rhs.sourceID {
      return lhs.sourceID < rhs.sourceID
    }
    return lhs.id < rhs.id
  }
}
