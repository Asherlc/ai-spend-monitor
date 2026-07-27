import XCTest

@testable import AISpendCore

final class DomainTests: XCTestCase {
  func testEveryFirstVersionProviderHasDescriptor() {
    XCTAssertEqual(Set(ProviderID.allCases), [.cursor, .claude, .openAI])
    XCTAssertEqual(ProviderDescriptor.builtIns.map(\.id), ProviderID.allCases)
  }

  func testSpendRecordRequiresHalfOpenPositiveInterval() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    XCTAssertThrowsError(
      try SpendRecord(
        id: "bad",
        provider: .claude,
        accountFingerprint: "acct",
        model: "claude",
        intervalStart: now,
        intervalEnd: now,
        amount: Money(1),
        quality: .estimated,
        sourceID: "log",
        observationID: "event",
        fetchedAt: now,
        estimate: nil
      )
    )
  }
}
