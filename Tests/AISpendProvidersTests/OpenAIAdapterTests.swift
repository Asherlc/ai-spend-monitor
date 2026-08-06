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
    XCTAssertEqual(rows.map(\.model), [nil, nil])
    XCTAssertEqual(rows.map(\.lineItem), ["gpt-5 input", "gpt-5 output"])
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

    XCTAssertEqual(
      result.refreshedSourceIDs,
      ["openai-local-logs", "openai-organization-costs"]
    )
    XCTAssertEqual(scanCount.value, 1)
    XCTAssertEqual(result.records.first?.amount, Money(2))
    XCTAssertEqual(result.records.first?.quality, .actual)
    XCTAssertEqual(
      result.attempts.map(\.outcome),
      [
        .succeeded(recordCount: 1), .succeeded(recordCount: 0),
      ])
  }

  func testCodexDiagnosticMarksCoveragePartialWithoutDiscardingLocalResults() async throws {
    let estimate = try makeSpendRecord(
      provider: .openAI,
      model: "gpt-5.3-codex",
      amount: 3,
      quality: .estimated
    )
    let adapter = OpenAIAdapter(
      credential: { Secret("admin") },
      actual: { _, _ in [] },
      local: { _, _ in
        LocalLogScanResult(
          records: [estimate],
          diagnostics: [.sourceUnavailable(file: "private-session-name.jsonl")]
        )
      },
      now: { juneDate() }
    )

    let result = try await adapter.fetch(window: juneWindow())

    XCTAssertEqual(
      result.coverage,
      .partial(message: "Some Codex local spend is unavailable.")
    )
    XCTAssertEqual(result.records.map(\.amount), [Money(3)])
    XCTAssertEqual(
      result.refreshedSourceIDs,
      ["openai-local-logs", "openai-organization-costs"]
    )
    XCTAssertEqual(result.attempts.last?.outcome, .succeeded(recordCount: 1))
  }

  func testOfficialModelLessCostCoverageSuppressesOnlyOverlappingLocalModels() async throws {
    let dayOneEnd = juneWindow().start.addingTimeInterval(86_400)
    let dayTwoEnd = dayOneEnd.addingTimeInterval(86_400)
    let overlapping = try makeSpendRecord(
      provider: .openAI,
      model: "gpt-5",
      amount: 8,
      quality: .estimated,
      intervalStart: juneWindow().start,
      intervalEnd: dayOneEnd
    )
    let uncovered = try makeSpendRecord(
      provider: .openAI,
      model: "gpt-5",
      amount: 4,
      quality: .estimated,
      intervalStart: dayOneEnd,
      intervalEnd: dayTwoEnd
    )
    let adapter = OpenAIAdapter(
      credential: { Secret("admin") },
      actual: { _, _ in
        [
          OpenAICostRow(
            start: juneWindow().start,
            end: dayOneEnd,
            amount: 2,
            model: nil,
            projectID: "project",
            lineItem: "API usage"
          )
        ]
      },
      local: { _, _ in
        LocalLogScanResult(records: [overlapping, uncovered], diagnostics: [])
      },
      fingerprinter: .production,
      now: { juneDate() }
    )

    let result = try await adapter.fetch(window: juneWindow())

    XCTAssertEqual(result.records.map(\.quality), [.actual, .estimated])
    XCTAssertEqual(result.records.map(\.amount), [Money(2), Money(4)])
  }

  func testCostClientSkipsRowsWithMissingOrIncompleteAmount() async throws {
    let client = OpenAICostClient(http: { request in
      let json = """
        {"object":"page","data":[{"object":"bucket","start_time":1780272000,"end_time":1780358400,"results":[{"object":"organization.costs.result","line_item":"missing","project_id":null},{"object":"organization.costs.result","amount":{"currency":"usd"},"line_item":"incomplete","project_id":null},{"object":"organization.costs.result","amount":{"value":"1.25","currency":"usd"},"line_item":"valid","project_id":null}]}],"has_more":false,"next_page":null}
        """
      return (Data(json.utf8), response(for: request, status: 200))
    })

    let rows = try await client.fetch(window: juneWindow(), credential: Secret("admin"))

    XCTAssertEqual(rows.map(\.amount), [Decimal(string: "1.25")!])
  }

  func testCostClientRejectsRepeatedPaginationCursor() async throws {
    let requests = RequestRecorder()
    let client = OpenAICostClient(http: { request in
      requests.append(request)
      return (
        Data(#"{"object":"page","data":[],"has_more":true,"next_page":"same"}"#.utf8),
        response(for: request, status: 200)
      )
    })

    await assertProviderThrows(
      try await client.fetch(window: juneWindow(), credential: Secret("admin")),
      expected: .invalidResponse
    )
    XCTAssertEqual(requests.count, 2)
  }

  func testProductionCredentialDiscoveryIgnoresOrdinaryAPIKey() throws {
    let adminHost = CredentialHost(
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
      environment: ["OPENAI_API_KEY": "ordinary", "OPENAI_ADMIN_KEY": "admin"]
    )
    XCTAssertEqual(
      try OpenAIAdapter.productionCredential(from: adminHost)?.withValue { $0 },
      "admin"
    )

    let ordinaryHost = CredentialHost(
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
      environment: ["OPENAI_API_KEY": "ordinary"]
    )
    XCTAssertNil(try OpenAIAdapter.productionCredential(from: ordinaryHost))
  }

  func testFailedActualNormalizationDoesNotSuppressCodexFallback() async throws {
    let estimate = try makeSpendRecord(
      provider: .openAI,
      model: "gpt-5",
      amount: 3,
      quality: .estimated
    )
    let adapter = OpenAIAdapter(
      credential: { Secret("admin") },
      actual: { _, _ in
        [
          OpenAICostRow(
            start: juneWindow().start,
            end: juneWindow().end,
            amount: -1,
            model: nil,
            projectID: nil,
            lineItem: "API usage"
          )
        ]
      },
      local: { _, _ in LocalLogScanResult(records: [estimate], diagnostics: []) },
      now: { juneDate() }
    )

    let result = try await adapter.fetch(window: juneWindow())

    XCTAssertEqual(result.records.map(\.quality), [.estimated])
    XCTAssertEqual(result.records.map(\.amount), [Money(3)])
  }
}
