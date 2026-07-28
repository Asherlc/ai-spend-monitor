import Foundation
import XCTest

@testable import AISpendCore

final class SpendAggregatorTests: XCTestCase {
  func testSummarizesActualAndEstimatedSpendByProviderAndModel() throws {
    let month = MonthWindow(
      start: Date(timeIntervalSince1970: 1_704_067_200),
      end: Date(timeIntervalSince1970: 1_706_745_600)
    )
    let actual = try record(
      id: "actual",
      model: "claude-opus",
      start: month.start,
      amount: 10,
      quality: .actual
    )
    let overlappingEstimate = try record(
      id: "overlapping-estimate",
      model: "claude-opus",
      start: month.start,
      amount: 12,
      quality: .estimated
    )
    let uncoveredEstimate = try record(
      id: "uncovered-estimate",
      model: "claude-sonnet",
      start: month.start.addingTimeInterval(86_400),
      amount: 3,
      quality: .estimated
    )
    let reconciled = SpendReconciler().reconcile([
      actual, overlappingEstimate, uncoveredEstimate,
    ])

    let summary = SpendAggregator().summarize(
      records: reconciled.included,
      enabledProviders: [.claude],
      window: month,
      providerFreshness: [.claude: .fresh]
    )

    XCTAssertEqual(summary.total, Money(13))
    XCTAssertEqual(summary.actual, Money(10))
    XCTAssertEqual(summary.estimated, Money(3))
    XCTAssertEqual(
      summary.providers.first?.models.map(\.model),
      [
        "claude-opus", "claude-sonnet",
      ])
    XCTAssertFalse(summary.isPartial)
  }

  func testIncludesOnlyEnabledProvidersWithBucketsStartingInMonth() throws {
    let month = MonthWindow(
      start: Date(timeIntervalSince1970: 1_704_067_200),
      end: Date(timeIntervalSince1970: 1_706_745_600)
    )
    let beforeMonth = try record(
      id: "before",
      start: month.start.addingTimeInterval(-1),
      amount: 20,
      quality: .actual
    )
    let monthStart = try record(
      id: "month-start",
      start: month.start,
      amount: 4,
      quality: .actual
    )
    let monthEnd = try record(
      id: "month-end",
      start: month.end,
      amount: 30,
      quality: .actual
    )
    let disabled = try record(
      id: "disabled",
      provider: .cursor,
      start: month.start,
      amount: 40,
      quality: .actual
    )

    let summary = SpendAggregator().summarize(
      records: [beforeMonth, monthStart, monthEnd, disabled],
      enabledProviders: [.claude],
      window: month,
      providerFreshness: [.claude: .fresh]
    )

    XCTAssertEqual(summary.total, Money(4))
    XCTAssertEqual(summary.providers.map(\.id), [.claude])
  }

  func testSortsProvidersAndModelsByDescendingAmountThenStableName() throws {
    let month = MonthWindow(
      start: Date(timeIntervalSince1970: 1_704_067_200),
      end: Date(timeIntervalSince1970: 1_706_745_600)
    )
    let records = [
      try record(
        id: "claude-zeta",
        provider: .claude,
        model: "zeta",
        start: month.start,
        amount: 5,
        quality: .estimated
      ),
      try record(
        id: "claude-alpha",
        provider: .claude,
        model: "alpha",
        start: month.start,
        amount: 5,
        quality: .actual
      ),
      try record(
        id: "cursor",
        provider: .cursor,
        model: "cursor-model",
        start: month.start,
        amount: 10,
        quality: .actual
      ),
      try record(
        id: "openai",
        provider: .openAI,
        model: "gpt",
        start: month.start,
        amount: 2,
        quality: .actual
      ),
    ]

    let summary = SpendAggregator().summarize(
      records: records,
      enabledProviders: [.claude, .cursor, .openAI],
      window: month,
      providerFreshness: [
        .claude: .fresh, .cursor: .fresh, .openAI: .fresh,
      ]
    )

    XCTAssertEqual(summary.providers.map(\.id), [.claude, .cursor, .openAI])
    XCTAssertEqual(summary.providers.first?.models.map(\.model), ["alpha", "zeta"])
  }

  func testMarksSummaryPartialForStaleOrUnavailableEnabledProvider() {
    let month = MonthWindow(
      start: Date(timeIntervalSince1970: 1_704_067_200),
      end: Date(timeIntervalSince1970: 1_706_745_600)
    )
    let aggregator = SpendAggregator()

    let stale = aggregator.summarize(
      records: [],
      enabledProviders: [.claude],
      window: month,
      providerFreshness: [.claude: .stale(age: 60)]
    )
    let unavailable = aggregator.summarize(
      records: [],
      enabledProviders: [.claude],
      window: month,
      providerFreshness: [.claude: .unavailable(message: "offline")]
    )
    XCTAssertTrue(stale.isPartial)
    XCTAssertTrue(unavailable.isPartial)
  }

  private func record(
    id: String,
    provider: ProviderID = .claude,
    model: String = "claude-opus",
    start: Date,
    amount: Decimal,
    quality: SpendQuality
  ) throws -> SpendRecord {
    try SpendRecord(
      id: id,
      provider: provider,
      accountFingerprint: "account",
      model: model,
      intervalStart: start,
      intervalEnd: start.addingTimeInterval(86_400),
      amount: Money(amount),
      quality: quality,
      sourceID: "source-\(id)",
      observationID: "observation-\(id)",
      fetchedAt: start,
      estimate: nil
    )
  }
}
