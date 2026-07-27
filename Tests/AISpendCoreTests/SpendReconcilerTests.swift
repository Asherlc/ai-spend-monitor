import Foundation
import XCTest

@testable import AISpendCore

final class SpendReconcilerTests: XCTestCase {
  func testActualSupersedesOnlyOverlappingEstimateInSameBillingGroup() throws {
    let dayOne = Date(timeIntervalSince1970: 1_704_067_200)
    let dayTwo = dayOne.addingTimeInterval(86_400)
    let dayThree = dayTwo.addingTimeInterval(86_400)
    let actual = try record(
      id: "actual",
      model: "claude-opus",
      start: dayOne,
      end: dayTwo,
      amount: 10,
      quality: .actual
    )
    let overlappingEstimate = try record(
      id: "overlapping-estimate",
      model: "claude-opus",
      start: dayOne,
      end: dayTwo,
      amount: 12,
      quality: .estimated
    )
    let uncoveredEstimate = try record(
      id: "uncovered-estimate",
      model: "claude-sonnet",
      start: dayTwo,
      end: dayThree,
      amount: 3,
      quality: .estimated
    )

    let result = SpendReconciler().reconcile([
      uncoveredEstimate, overlappingEstimate, actual,
    ])

    XCTAssertEqual(result.included.map(\.id), [actual.id, uncoveredEstimate.id])
    XCTAssertEqual(result.excludedEstimatedAmount, Money(12))
    XCTAssertEqual(result.excludedRecordIDs, [overlappingEstimate.id])
  }

  func testReconciliationNeverCrossesProviderAccountOrModelBoundaries() throws {
    let start = Date(timeIntervalSince1970: 1_704_067_200)
    let end = start.addingTimeInterval(86_400)
    let actual = try record(
      id: "actual",
      model: "claude-opus",
      start: start,
      end: end,
      amount: 10,
      quality: .actual
    )
    let otherProvider = try record(
      id: "cursor-estimate",
      provider: .cursor,
      model: "claude-opus",
      start: start,
      end: end,
      amount: 4,
      quality: .estimated
    )
    let otherAccount = try record(
      id: "other-account-estimate",
      accountFingerprint: "other-account",
      model: "claude-opus",
      start: start,
      end: end,
      amount: 5,
      quality: .estimated
    )
    let otherModel = try record(
      id: "other-model-estimate",
      model: "claude-sonnet",
      start: start,
      end: end,
      amount: 6,
      quality: .estimated
    )

    let result = SpendReconciler().reconcile([
      otherModel, otherProvider, actual, otherAccount,
    ])

    XCTAssertEqual(
      Set(result.included.map(\.id)),
      [actual.id, otherProvider.id, otherAccount.id, otherModel.id]
    )
    XCTAssertEqual(result.excludedEstimatedAmount, .zero)
  }

  func testAdjacentEstimateDoesNotIntersectActualHalfOpenCoverage() throws {
    let dayOne = Date(timeIntervalSince1970: 1_704_067_200)
    let dayTwo = dayOne.addingTimeInterval(86_400)
    let dayThree = dayTwo.addingTimeInterval(86_400)
    let actual = try record(
      id: "actual",
      start: dayOne,
      end: dayTwo,
      amount: 10,
      quality: .actual
    )
    let adjacentEstimate = try record(
      id: "adjacent-estimate",
      start: dayTwo,
      end: dayThree,
      amount: 3,
      quality: .estimated
    )

    let result = SpendReconciler().reconcile([adjacentEstimate, actual])

    XCTAssertEqual(result.included.map(\.id), [actual.id, adjacentEstimate.id])
    XCTAssertEqual(result.excludedEstimatedAmount, .zero)
  }

  func testDuplicateObservationIsCountedOnceWithinItsBillingGroup() throws {
    let start = Date(timeIntervalSince1970: 1_704_067_200)
    let end = start.addingTimeInterval(86_400)
    let first = try record(
      id: "b",
      start: start,
      end: end,
      amount: 7,
      quality: .actual,
      observationID: "same-observation"
    )
    let duplicate = try record(
      id: "a",
      start: start,
      end: end,
      amount: 7,
      quality: .actual,
      observationID: "same-observation"
    )
    let sameObservationOtherProvider = try record(
      id: "cursor",
      provider: .cursor,
      start: start,
      end: end,
      amount: 2,
      quality: .actual,
      observationID: "same-observation"
    )

    let result = SpendReconciler().reconcile([
      first, sameObservationOtherProvider, duplicate,
    ])

    XCTAssertEqual(result.included.map(\.id), ["a", "cursor"])
  }

  func testEstimatedDuplicateOfActualContributesExcludedAmount() throws {
    let start = Date(timeIntervalSince1970: 1_704_067_200)
    let end = start.addingTimeInterval(86_400)
    let actual = try record(
      id: "actual",
      start: start,
      end: end,
      amount: 10,
      quality: .actual,
      observationID: "same-observation"
    )
    let estimate = try record(
      id: "estimate",
      start: start,
      end: end,
      amount: 12,
      quality: .estimated,
      observationID: "same-observation"
    )

    let result = SpendReconciler().reconcile([estimate, actual])

    XCTAssertEqual(result.included.map(\.id), [actual.id])
    XCTAssertEqual(result.excludedRecordIDs, [estimate.id])
    XCTAssertEqual(result.excludedEstimatedAmount, Money(12))
  }

  func testPartiallyOverlappingEstimateIsFullyExcluded() throws {
    let dayOne = Date(timeIntervalSince1970: 1_704_067_200)
    let dayTwo = dayOne.addingTimeInterval(86_400)
    let dayThree = dayTwo.addingTimeInterval(86_400)
    let dayFour = dayThree.addingTimeInterval(86_400)
    let actual = try record(
      id: "actual",
      start: dayOne,
      end: dayThree,
      amount: 10,
      quality: .actual
    )
    let partiallyOverlappingEstimate = try record(
      id: "partially-overlapping-estimate",
      start: dayTwo,
      end: dayFour,
      amount: 12,
      quality: .estimated
    )

    let result = SpendReconciler().reconcile([
      partiallyOverlappingEstimate, actual,
    ])

    XCTAssertEqual(result.included.map(\.id), [actual.id])
    XCTAssertEqual(result.excludedRecordIDs, [partiallyOverlappingEstimate.id])
    XCTAssertEqual(result.excludedEstimatedAmount, Money(12))
  }

  private func record(
    id: String,
    provider: ProviderID = .claude,
    accountFingerprint: String = "account",
    model: String = "claude-opus",
    start: Date,
    end: Date,
    amount: Decimal,
    quality: SpendQuality,
    observationID: String? = nil
  ) throws -> SpendRecord {
    try SpendRecord(
      id: id,
      provider: provider,
      accountFingerprint: accountFingerprint,
      model: model,
      intervalStart: start,
      intervalEnd: end,
      amount: Money(amount),
      quality: quality,
      sourceID: "source-\(id)",
      observationID: observationID ?? "observation-\(id)",
      fetchedAt: end,
      estimate: nil
    )
  }
}
