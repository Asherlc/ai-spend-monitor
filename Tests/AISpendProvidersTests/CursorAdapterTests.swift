import AISpendCore
import Foundation
import XCTest

@testable import AISpendProviders

final class CursorAdapterTests: XCTestCase {
  func testClientPagesSpendAndUsageFiltersEventsAndIgnoresRequestUnits() async throws {
    let spend = try fixtureData("cursor-spend")
    let usage = try fixtureData("cursor-usage-events")
    let requests = RequestRecorder()
    let client = CursorUsageClient(http: { request in
      requests.append(request)
      let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
      if request.url!.path.hasSuffix("/spend") {
        if body.contains(#""page":2"#) {
          return (
            Data(
              #"{"teamMemberSpend":[{"spendCents":100.25,"fastPremiumRequests":0,"name":"Three","email":"three@example.invalid","role":"member","hardLimitOverrideDollars":0}],"subscriptionCycleStart":1780272000000,"totalMembers":3,"totalPages":2}"#
                .utf8),
            response(for: request, status: 200)
          )
        }
        return (spend, response(for: request, status: 200))
      }
      if body.contains(#""page":2"#) {
        return (
          Data(
            #"{"totalUsageEventsCount":4,"pagination":{"numPages":2,"currentPage":2,"pageSize":3,"hasNextPage":false,"hasPreviousPage":true},"usageEvents":[{"timestamp":"1781136000000","model":"gpt-5","kind":"Usage-based","maxMode":false,"requestsCosts":777,"isTokenBasedCall":true,"tokenUsage":{"inputTokens":1,"outputTokens":1,"cacheWriteTokens":0,"cacheReadTokens":0,"totalCents":125.25},"isFreeBugbot":false,"userEmail":"sanitized@example.invalid"}],"period":{"startDate":1780272000000,"endDate":1782864000000}}"#
              .utf8),
          response(for: request, status: 200)
        )
      }
      return (usage, response(for: request, status: 200))
    })

    let result = try await client.fetch(
      window: juneWindow(),
      authorization: .adminKey(Secret("cursor-admin"))
    )

    XCTAssertEqual(result.authoritativeCents, Decimal(string: "600.375")!)
    XCTAssertEqual(
      result.modelCents,
      [
        "claude-sonnet-4-5": Decimal(string: "225.125")!,
        "gpt-5": Decimal(string: "125.25")!,
      ])
    XCTAssertEqual(requests.count, 4)
    XCTAssertTrue(
      requests.requests.allSatisfy {
        $0.value(forHTTPHeaderField: "Authorization") == "Basic Y3Vyc29yLWFkbWluOg=="
      }
    )
  }

  func testAdapterEmitsPositiveUnknownRemainder() async throws {
    let adapter = CursorAdapter(
      authorization: { .adminKey(Secret("key")) },
      usage: { _, _ in
        CursorUsageResult(
          authoritativeCents: 600,
          modelCents: ["claude-sonnet-4-5": 225, "gpt-5": 125]
        )
      },
      now: { juneWindow().end }
    )

    let result = try await adapter.fetch(window: juneWindow())

    XCTAssertEqual(
      Dictionary(uniqueKeysWithValues: result.records.map { ($0.model, $0.amount.amount) }),
      [
        "claude-sonnet-4-5": Decimal(string: "2.25")!,
        "gpt-5": Decimal(string: "1.25")!,
        "unknown": Decimal(string: "2.50")!,
      ])
  }

  func testAdapterUsesAllUnknownAndDiagnosticWhenAttributionExceedsTotal() async throws {
    let adapter = CursorAdapter(
      authorization: { .appToken(token: Secret("app"), teamID: Secret("team")) },
      usage: { _, _ in
        CursorUsageResult(authoritativeCents: 100, modelCents: ["gpt-5": 125])
      },
      now: { juneWindow().end }
    )

    let result = try await adapter.fetch(window: juneWindow())

    XCTAssertEqual(result.records.map(\.model), ["unknown"])
    XCTAssertEqual(result.records.first?.amount, Money(1))
    XCTAssertEqual(result.attempts.count, 2)
    guard case .failed(let message) = result.attempts[1].outcome else {
      return XCTFail("Expected schema mismatch diagnostic")
    }
    XCTAssertTrue(message.contains("schema mismatch"))
    XCTAssertFalse(message.contains("app"))
  }

  func testAdapterIsUnavailableWithoutAdminOrAuthenticatedAppState() async throws {
    let adapter = CursorAdapter(
      authorization: { nil },
      usage: { _, _ in
        XCTFail("Usage must not run")
        return CursorUsageResult(authoritativeCents: 0, modelCents: [:])
      },
      now: { juneWindow().end }
    )

    let result = try await adapter.fetch(window: juneWindow())

    XCTAssertTrue(result.records.isEmpty)
    XCTAssertEqual(
      result.attempts,
      [
        SourceAttempt(
          strategyID: "cursor-actual",
          outcome: .unavailable(reason: "No Cursor admin credential or authenticated app state.")
        )
      ])
  }

  func testAdapterTreatsMissingCursorStateAsUnavailable() async throws {
    let adapter = CursorAdapter(
      authorization: { throw SourceHostError.sourceUnavailable },
      usage: { _, _ in
        XCTFail("Usage must not run")
        return CursorUsageResult(authoritativeCents: 0, modelCents: [:])
      },
      now: { juneWindow().end }
    )

    let result = try await adapter.fetch(window: juneWindow())

    XCTAssertTrue(result.records.isEmpty)
    XCTAssertEqual(
      result.attempts.first?.outcome,
      .unavailable(reason: "No Cursor admin credential or authenticated app state.")
    )
  }
}

final class RequestRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [URLRequest] = []

  var requests: [URLRequest] { lock.withLock { stored } }
  var count: Int { lock.withLock { stored.count } }
  func append(_ request: URLRequest) { lock.withLock { stored.append(request) } }
}

final class LockedInt: @unchecked Sendable {
  private let lock = NSLock()
  private var stored = 0
  var value: Int { lock.withLock { stored } }
  func increment() { lock.withLock { stored += 1 } }
}

func fixtureData(_ name: String) throws -> Data {
  try Data(
    contentsOf: XCTUnwrap(
      Bundle.module.url(
        forResource: name,
        withExtension: "json",
        subdirectory: "Fixtures"
      )
    )
  )
}

func juneWindow() -> MonthWindow {
  MonthWindow(
    start: ISO8601DateFormatter().date(from: "2026-06-01T00:00:00Z")!,
    end: ISO8601DateFormatter().date(from: "2026-07-01T00:00:00Z")!
  )
}

func response(for request: URLRequest, status: Int) -> HTTPURLResponse {
  HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
}

func makeSpendRecord(
  provider: ProviderID,
  model: String,
  amount: Decimal,
  quality: SpendQuality,
  accountFingerprint: String = "test"
) throws -> SpendRecord {
  try SpendRecord(
    id: UUID().uuidString,
    provider: provider,
    accountFingerprint: accountFingerprint,
    model: model,
    intervalStart: juneWindow().start,
    intervalEnd: juneWindow().end,
    amount: Money(amount),
    quality: quality,
    sourceID: "test",
    observationID: UUID().uuidString,
    fetchedAt: juneWindow().end,
    estimate: nil
  )
}
