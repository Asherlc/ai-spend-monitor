import AISpendCore
import Foundation
import XCTest

@testable import AISpendProviders

final class OpenAIAdapterTests: XCTestCase {
  func testCostClientPaginatesPreservesDetailAndRejectsNonUSD() async throws {
    let fixture = try fixtureData("openai-costs")
    let requests = RequestRecorder()
    let client = OpenAICostClient(http: { request in
      requests.append(request)
      if requests.count == 1 {
        return (fixture, response(for: request, status: 200))
      }
      return (
        Data(#"{"object":"page","data":[],"has_more":false,"next_page":null}"#.utf8),
        response(for: request, status: 200)
      )
    })

    let rows = try await client.fetch(window: juneWindow(), credential: Secret("admin"))

    XCTAssertEqual(rows.count, 2)
    XCTAssertEqual(rows.map(\.amount), [Decimal(string: "1.2505")!, Decimal(string: "0.75")!])
    XCTAssertEqual(rows.map(\.model), ["gpt-5 input", "gpt-5 output"])
    XCTAssertEqual(rows.map(\.projectID), ["proj_sanitized", "proj_sanitized"])
    XCTAssertEqual(requests.count, 2)
    let query = try XCTUnwrap(
      URLComponents(url: requests.requests[0].url!, resolvingAgainstBaseURL: false)?
        .queryItems
    )
    XCTAssertEqual(
      query.filter { $0.name == "group_by" }.map(\.value),
      [
        "project_id", "line_item",
      ])
    XCTAssertEqual(query.first { $0.name == "bucket_width" }?.value, "1d")
    XCTAssertEqual(query.first { $0.name == "start_time" }?.value, "1780272000")
    XCTAssertTrue(requests.requests[1].url!.absoluteString.contains("page=openai-page-2"))
  }

  func testAdapterAlwaysRunsCodexEstimateAfterAuthoritativeFetch() async throws {
    let scanCount = LockedInt()
    let adapter = OpenAIAdapter(
      credential: { Secret("admin") },
      actual: { _, _ in
        [
          OpenAICostRow(
            start: juneWindow().start,
            end: juneWindow().start.addingTimeInterval(86_400),
            amount: 2,
            model: "gpt-5",
            projectID: "project",
            lineItem: "input"
          )
        ]
      },
      local: { _, _ in
        scanCount.increment()
        return LocalLogScanResult(records: [], diagnostics: [])
      },
      now: { juneWindow().end }
    )

    let result = try await adapter.fetch(window: juneWindow())

    XCTAssertEqual(scanCount.value, 1)
    XCTAssertEqual(result.records.first?.amount, Money(2))
    XCTAssertEqual(result.records.first?.quality, .actual)
    XCTAssertEqual(
      result.attempts.map(\.outcome),
      [
        .succeeded(recordCount: 1), .succeeded(recordCount: 0),
      ])
  }
}
