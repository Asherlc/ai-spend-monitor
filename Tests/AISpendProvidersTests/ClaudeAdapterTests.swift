import AISpendCore
import Foundation
import XCTest

@testable import AISpendProviders

final class ClaudeAdapterTests: XCTestCase {
  func testCostClientPaginatesAndConvertsLowestUnitsToUSD() async throws {
    let fixture = try fixtureData("anthropic-cost-report")
    let requests = RequestRecorder()
    let client = ClaudeCostClient(http: { request in
      requests.append(request)
      if requests.count == 1 {
        return (fixture, response(for: request, status: 200))
      }
      let page = """
        {"data":[{"starting_at":"2026-06-02T00:00:00Z","ending_at":"2026-06-03T00:00:00Z","results":[{"amount":"50","currency":"USD","description":"Tokens","model":"claude-opus-4-1"}]}],"has_more":false,"next_page":null}
        """
      return (Data(page.utf8), response(for: request, status: 200))
    })

    let rows = try await client.fetch(window: juneWindow(), credential: .adminKey(Secret("secret")))

    XCTAssertEqual(
      rows.map(\.amount),
      [
        Decimal(string: "1.255")!,
        Decimal(string: "0.0025")!,
        Decimal(string: "0.1005")!,
        Decimal(string: "0.5")!,
      ])
    XCTAssertEqual(requests.count, 2)
    let first = try XCTUnwrap(requests.requests.first)
    XCTAssertEqual(first.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    XCTAssertEqual(first.value(forHTTPHeaderField: "x-api-key"), "secret")
    let query = try XCTUnwrap(URLComponents(url: first.url!, resolvingAgainstBaseURL: false))
      .queryItems
    XCTAssertEqual(query?.filter { $0.name == "group_by[]" }.map(\.value), ["description"])
    XCTAssertEqual(query?.first { $0.name == "bucket_width" }?.value, "1d")
    XCTAssertEqual(
      query?.first { $0.name == "starting_at" }?.value,
      "2026-06-01T00:00:00Z"
    )
    XCTAssertEqual(
      query?.first { $0.name == "ending_at" }?.value,
      "2026-07-01T00:00:00Z"
    )
    XCTAssertTrue(requests.requests[1].url!.absoluteString.contains("page=anthropic-page-2"))
  }

  func testAdapterRunsLocalEstimateAfterActualAndRedactsAuthFailure() async throws {
    let scanCount = LockedInt()
    let estimated = try makeSpendRecord(
      provider: .claude,
      model: "local",
      amount: 1,
      quality: .estimated
    )
    let adapter = ClaudeAdapter(
      credential: { .bearerToken(Secret("token-value")) },
      actual: { _, _ in throw ProviderClientError.httpStatus(403) },
      local: { _, _ in
        scanCount.increment()
        return LocalLogScanResult(records: [estimated], diagnostics: [])
      },
      now: { juneWindow().end }
    )

    let result = try await adapter.fetch(window: juneWindow())

    XCTAssertEqual(result.records, [estimated])
    XCTAssertEqual(scanCount.value, 1)
    XCTAssertEqual(result.attempts.count, 2)
    guard case .failed(let message) = result.attempts[0].outcome else {
      return XCTFail("Expected redacted failure")
    }
    XCTAssertFalse(message.contains("token-value"))
    XCTAssertEqual(result.attempts[1].outcome, .succeeded(recordCount: 1))
  }

  func testActualAndLocalRecordsShareAReconciliationBillingGroup() async throws {
    let estimate = try makeSpendRecord(
      provider: .claude,
      model: "claude-sonnet-4-5",
      amount: 9,
      quality: .estimated,
      accountFingerprint: "local"
    )
    let adapter = ClaudeAdapter(
      credential: { .adminKey(Secret("admin")) },
      actual: { _, _ in
        [
          ClaudeCostRow(
            start: juneWindow().start,
            end: juneWindow().end,
            amount: 2,
            description: "Tokens",
            model: "claude-sonnet-4-5"
          )
        ]
      },
      local: { _, _ in LocalLogScanResult(records: [estimate], diagnostics: []) },
      now: { juneWindow().end }
    )

    let result = try await adapter.fetch(window: juneWindow())
    let reconciled = SpendReconciler().reconcile(result.records)

    XCTAssertEqual(result.records.map(\.accountFingerprint), ["local", "local"])
    XCTAssertEqual(reconciled.included.map(\.quality), [.actual])
    XCTAssertEqual(reconciled.included.map(\.amount).reduce(.zero, +), Money(2))
  }
}
