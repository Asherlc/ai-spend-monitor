import Foundation

public struct ReconciliationResult: Sendable {
  public let included: [SpendRecord]
  public let excludedEstimatedAmount: Money
  public let excludedRecordIDs: Set<String>

  public init(
    included: [SpendRecord],
    excludedEstimatedAmount: Money,
    excludedRecordIDs: Set<String>
  ) {
    self.included = included
    self.excludedEstimatedAmount = excludedEstimatedAmount
    self.excludedRecordIDs = excludedRecordIDs
  }
}

public struct SpendReconciler: Sendable {
  public init() {}

  public func reconcile(_ records: [SpendRecord]) -> ReconciliationResult {
    var recordsByObservation: [ObservationKey: SpendRecord] = [:]
    var excludedRecordIDs: Set<String> = []
    var excludedEstimatedAmount = Money.zero

    for record in records.sorted(by: Self.prefersForDuplicateObservation) {
      let key = ObservationKey(record: record)
      if recordsByObservation[key] == nil {
        recordsByObservation[key] = record
      } else {
        excludedRecordIDs.insert(record.id)
        if record.quality == .estimated {
          excludedEstimatedAmount = excludedEstimatedAmount + record.amount
        }
      }
    }

    let deduplicated = Array(recordsByObservation.values)
    let actualCoverage = Dictionary(
      grouping: deduplicated.filter { $0.quality == .actual },
      by: BillingGroup.init(record:)
    )
    var included: [SpendRecord] = []

    for record in deduplicated {
      let isCoveredEstimate =
        record.quality == .estimated
        && actualCoverage[BillingGroup(record: record), default: []].contains {
          Self.intersects(record, $0)
        }

      if isCoveredEstimate {
        excludedEstimatedAmount = excludedEstimatedAmount + record.amount
        excludedRecordIDs.insert(record.id)
      } else {
        included.append(record)
      }
    }

    included.sort(by: Self.ordersIncludedRecords)
    return ReconciliationResult(
      included: included,
      excludedEstimatedAmount: excludedEstimatedAmount,
      excludedRecordIDs: excludedRecordIDs
    )
  }

  private static func intersects(_ lhs: SpendRecord, _ rhs: SpendRecord) -> Bool {
    lhs.intervalStart < rhs.intervalEnd && rhs.intervalStart < lhs.intervalEnd
  }

  private static func prefersForDuplicateObservation(
    _ lhs: SpendRecord,
    _ rhs: SpendRecord
  ) -> Bool {
    if lhs.quality != rhs.quality {
      return lhs.quality == .actual
    }
    if lhs.amount != rhs.amount {
      return lhs.amount < rhs.amount
    }
    if lhs.intervalStart != rhs.intervalStart {
      return lhs.intervalStart < rhs.intervalStart
    }
    if lhs.intervalEnd != rhs.intervalEnd {
      return lhs.intervalEnd < rhs.intervalEnd
    }
    if lhs.sourceID != rhs.sourceID {
      return lhs.sourceID < rhs.sourceID
    }
    return lhs.id < rhs.id
  }

  private static func ordersIncludedRecords(_ lhs: SpendRecord, _ rhs: SpendRecord) -> Bool {
    if lhs.intervalStart != rhs.intervalStart {
      return lhs.intervalStart < rhs.intervalStart
    }
    if lhs.provider != rhs.provider {
      return lhs.provider.rawValue < rhs.provider.rawValue
    }
    if lhs.model != rhs.model {
      return lhs.model < rhs.model
    }
    return lhs.id < rhs.id
  }
}

private struct BillingGroup: Hashable {
  let provider: ProviderID
  let accountFingerprint: String
  let model: String

  init(record: SpendRecord) {
    provider = record.provider
    accountFingerprint = record.accountFingerprint
    model = record.model
  }
}

private struct ObservationKey: Hashable {
  let group: BillingGroup
  let observationID: String

  init(record: SpendRecord) {
    group = BillingGroup(record: record)
    observationID = record.observationID
  }
}
