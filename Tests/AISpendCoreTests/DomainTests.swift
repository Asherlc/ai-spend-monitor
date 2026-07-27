import XCTest

@testable import AISpendCore

final class DomainTests: XCTestCase {
  func testSpendRecordDecodeUsesValidatedInitializer() throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let encodedDate = date.timeIntervalSinceReferenceDate
    let data = """
      {
        "id": "bad",
        "provider": "claude",
        "accountFingerprint": "acct",
        "model": "claude",
        "intervalStart": \(encodedDate),
        "intervalEnd": \(encodedDate),
        "amount": {"amount": "1", "currency": "USD"},
        "quality": "estimated",
        "sourceID": "log",
        "observationID": "event",
        "fetchedAt": \(encodedDate)
      }
      """.data(using: .utf8)!

    XCTAssertThrowsError(try JSONDecoder().decode(SpendRecord.self, from: data))
  }

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
