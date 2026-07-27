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

    XCTAssertEqual(result.records.map(\.amount), [estimated.amount])
    XCTAssertEqual(result.records.map(\.model), [estimated.model])
    XCTAssertNotEqual(result.records.first?.accountFingerprint, "test")
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
      fingerprinter: .production,
      now: { juneDate() }
    )

    let result = try await adapter.fetch(window: juneWindow())
    let reconciled = SpendReconciler().reconcile(result.records)

    XCTAssertEqual(Set(result.records.map(\.accountFingerprint)).count, 1)
    XCTAssertFalse(result.records[0].accountFingerprint.contains("admin"))
    XCTAssertEqual(reconciled.included.map(\.quality), [.actual])
    XCTAssertEqual(reconciled.included.map(\.amount).reduce(.zero, +), Money(2))
  }

  func testModelLessActualCoverageSuppressesOnlyOverlappingLocalEstimates() async throws {
    let dayOneEnd = juneWindow().start.addingTimeInterval(86_400)
    let dayTwoEnd = dayOneEnd.addingTimeInterval(86_400)
    let overlapping = try makeSpendRecord(
      provider: .claude,
      model: "claude-sonnet-4-5",
      amount: 9,
      quality: .estimated,
      intervalStart: juneWindow().start,
      intervalEnd: dayOneEnd
    )
    let uncovered = try makeSpendRecord(
      provider: .claude,
      model: "claude-opus-4-1",
      amount: 3,
      quality: .estimated,
      intervalStart: dayOneEnd,
      intervalEnd: dayTwoEnd
    )
    let adapter = ClaudeAdapter(
      credential: { .adminKey(Secret("admin")) },
      actual: { _, _ in
        [
          ClaudeCostRow(
            start: juneWindow().start,
            end: dayOneEnd,
            amount: 2,
            description: "Tokens",
            model: nil
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
    XCTAssertEqual(result.records.map(\.amount), [Money(2), Money(3)])
    XCTAssertEqual(result.records.last?.model, "claude-opus-4-1")
  }

  func testProductionCredentialDiscoveryUsesOnlyAdminAndOAuthVariables() throws {
    let host = CredentialHost(
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
      environment: [
        "ANTHROPIC_API_KEY": "ordinary",
        "ANTHROPIC_ADMIN_KEY": "admin",
        "ANTHROPIC_OAUTH_TOKEN": "oauth",
      ]
    )

    guard case .adminKey(let admin)? = try ClaudeAdapter.productionCredential(from: host) else {
      return XCTFail("Expected admin key to take precedence")
    }
    XCTAssertEqual(admin.withValue { $0 }, "admin")

    let oauthOnly = CredentialHost(
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
      environment: [
        "ANTHROPIC_API_KEY": "ordinary",
        "ANTHROPIC_OAUTH_TOKEN": "oauth",
      ]
    )
    guard case .bearerToken(let oauth)? = try ClaudeAdapter.productionCredential(from: oauthOnly)
    else {
      return XCTFail("Expected OAuth bearer")
    }
    XCTAssertEqual(oauth.withValue { $0 }, "oauth")

    let ordinaryOnly = CredentialHost(
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
      environment: ["ANTHROPIC_API_KEY": "ordinary"]
    )
    XCTAssertNil(try ClaudeAdapter.productionCredential(from: ordinaryOnly))
  }

  func testCostClientRejectsRepeatedPaginationCursor() async throws {
    let requests = RequestRecorder()
    let client = ClaudeCostClient(http: { request in
      requests.append(request)
      return (
        Data(
          #"{"data":[],"has_more":true,"next_page":"same"}"#.utf8
        ),
        response(for: request, status: 200)
      )
    })

    await assertProviderThrows(
      try await client.fetch(window: juneWindow(), credential: .adminKey(Secret("admin"))),
      expected: .invalidResponse
    )
    XCTAssertEqual(requests.count, 2)
  }

  func testCostClientRejectsMoreThanHundredPages() async throws {
    let requests = RequestRecorder()
    let client = ClaudeCostClient(http: { request in
      requests.append(request)
      let next = "page-\(requests.count)"
      return (
        Data(#"{"data":[],"has_more":true,"next_page":"\#(next)"}"#.utf8),
        response(for: request, status: 200)
      )
    })

    await assertProviderThrows(
      try await client.fetch(window: juneWindow(), credential: .adminKey(Secret("admin"))),
      expected: .invalidResponse
    )
    XCTAssertEqual(requests.count, 100)
  }

  func testCostClientStopsBeforeTransportWhenTaskIsCancelled() async {
    let requests = RequestRecorder()
    let client = ClaudeCostClient(http: { request in
      requests.append(request)
      return (
        Data(#"{"data":[],"has_more":false,"next_page":null}"#.utf8),
        response(for: request, status: 200)
      )
    })
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await client.fetch(
        window: juneWindow(),
        credential: .adminKey(Secret("admin"))
      )
    }

    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      XCTAssertEqual(requests.count, 0)
    } catch {
      XCTFail("Expected CancellationError, got \(error)")
    }
  }

  func testAdapterCancellationStopsBeforeActualAndLocalSources() async {
    let invocationCount = LockedInt()
    let adapter = ClaudeAdapter(
      credential: { .adminKey(Secret("admin")) },
      actual: { _, _ in
        invocationCount.increment()
        return []
      },
      local: { _, _ in
        invocationCount.increment()
        return LocalLogScanResult(records: [], diagnostics: [])
      },
      now: { juneDate() }
    )
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await adapter.fetch(window: juneWindow())
    }

    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      XCTAssertEqual(invocationCount.value, 0)
    } catch {
      XCTFail("Expected CancellationError, got \(error)")
    }
  }

  func testCredentialCancellationIsRethrown() async {
    let adapter = ClaudeAdapter(
      credential: { throw CancellationError() },
      actual: { _, _ in [] },
      local: { _, _ in LocalLogScanResult(records: [], diagnostics: []) },
      now: { juneDate() }
    )

    do {
      _ = try await adapter.fetch(window: juneWindow())
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      XCTAssertTrue(true)
    } catch {
      XCTFail("Expected CancellationError, got \(error)")
    }
  }

  func testFailedActualNormalizationDoesNotSuppressLocalFallback() async throws {
    let estimate = try makeSpendRecord(
      provider: .claude,
      model: "claude-sonnet-4-5",
      amount: 3,
      quality: .estimated
    )
    let adapter = ClaudeAdapter(
      credential: { .adminKey(Secret("admin")) },
      actual: { _, _ in
        [
          ClaudeCostRow(
            start: juneWindow().start,
            end: juneWindow().end,
            amount: -1,
            description: "Tokens",
            model: nil
          )
        ]
      },
      local: { _, _ in LocalLogScanResult(records: [estimate], diagnostics: []) },
      now: { juneDate() }
    )

    let result = try await adapter.fetch(window: juneWindow())

    XCTAssertEqual(result.records.map(\.quality), [.estimated])
    XCTAssertEqual(result.records.map(\.amount), [Money(3)])
    guard case .failed = result.attempts[0].outcome else {
      return XCTFail("Expected actual normalization failure")
    }
  }

  func testLocalScannerRethrowsCancellationRaisedMidFile() async throws {
    let root = try emptyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("cancel.jsonl")
    try Data("{}\n{}\n".utf8).write(to: file)
    try setModificationDate(file)
    let scanner = LocalLogScanner(
      provider: .claude,
      sessionRoots: [root],
      priceCatalog: try PriceCatalog.bundled(),
      calendar: utcCalendar(),
      parser: { _, _ in
        withUnsafeCurrentTask { $0?.cancel() }
        return nil
      }
    )
    let task = Task {
      try scanner.scan(window: juneWindow(), fetchedAt: juneDate())
    }

    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      XCTAssertTrue(true)
    } catch {
      XCTFail("Expected CancellationError, got \(error)")
    }
  }
}
