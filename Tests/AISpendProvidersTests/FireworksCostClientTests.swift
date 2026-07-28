import AISpendCore
import Foundation
import XCTest

@testable import AISpendProviders

final class FireworksCostClientTests: XCTestCase {
  func testCostsPostsDayModelQueryAndDecodesMoney() async throws {
    let requests = RequestRecorder()
    let first = try fixtureData("fireworks-costs-page")
    let client = FireworksCostClient(http: { request in
      requests.append(request)
      let body =
        requests.count == 1
        ? first
        : Data(
          #"{"rows":[],"nextPageToken":"","subtotal":{"currencyCode":"USD","units":"3","nanos":0}}"#
            .utf8
        )
      return (body, response(for: request, status: 200))
    })

    let result = try await client.costs(
      account: FireworksAccount(resourceName: "accounts/personal", id: "personal"),
      window: juneWindow(),
      scope: .account,
      credential: Secret("fw_secret")
    )

    XCTAssertEqual(
      result.rows.map(\.amount),
      [Decimal(string: "1.25")!, Decimal(string: "0.75")!]
    )
    XCTAssertEqual(
      result.rows.map(\.model),
      ["accounts/fireworks/models/kimi-k2", "unknown"]
    )
    XCTAssertEqual(result.subtotal, 3)
    XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(requests.requests[0].httpMethod, "POST")
    XCTAssertEqual(
      requests.requests[0].url?.absoluteString,
      "https://api.fireworks.ai/v1/accounts/personal/usageCosts:query"
    )
    XCTAssertEqual(
      requests.requests[0].value(forHTTPHeaderField: "Authorization"),
      "Bearer fw_secret"
    )
    XCTAssertEqual(
      requests.requests[0].value(forHTTPHeaderField: "Content-Type"),
      "application/json"
    )
    XCTAssertEqual(
      requests.requests[0].value(forHTTPHeaderField: "Accept"),
      "application/json"
    )
    let body =
      try JSONSerialization.jsonObject(
        with: try XCTUnwrap(requests.requests[0].httpBody)
      ) as! [String: Any]
    XCTAssertEqual(
      Set(body.keys),
      Set(["startTime", "endTime", "scope", "groupBy", "pageSize"])
    )
    XCTAssertEqual(body["scope"] as? String, "ACCOUNT")
    XCTAssertEqual(body["groupBy"] as? [String], ["DAY", "MODEL"])
    XCTAssertEqual(body["pageSize"] as? Int, 1000)
    XCTAssertEqual(body["startTime"] as? String, "2026-06-01T00:00:00Z")
    XCTAssertEqual(body["endTime"] as? String, "2026-07-01T00:00:00Z")
    XCTAssertNil(body["pageToken"])

    let nextBody =
      try JSONSerialization.jsonObject(
        with: try XCTUnwrap(requests.requests[1].httpBody)
      ) as! [String: Any]
    XCTAssertEqual(
      Set(nextBody.keys),
      Set(["startTime", "endTime", "scope", "groupBy", "pageSize", "pageToken"])
    )
    XCTAssertEqual(nextBody["pageToken"] as? String, "cost-page-2")
  }

  func testCostsUsesExactSelfQueryBody() async throws {
    let requests = RequestRecorder()
    let client = FireworksCostClient(http: { request in
      requests.append(request)
      return (
        Data(
          #"{"rows":[],"subtotal":{"currencyCode":"USD","units":"0","nanos":0}}"#.utf8
        ),
        response(for: request, status: 200)
      )
    })

    _ = try await client.costs(
      account: FireworksAccount(resourceName: "accounts/personal", id: "personal"),
      window: juneWindow(),
      scope: .personal,
      credential: Secret("fw_secret")
    )

    let body =
      try JSONSerialization.jsonObject(
        with: try XCTUnwrap(requests.requests[0].httpBody)
      ) as! [String: Any]
    XCTAssertEqual(
      Set(body.keys),
      Set(["startTime", "endTime", "scope", "groupBy", "pageSize"])
    )
    XCTAssertEqual(body["scope"] as? String, "SELF")
    XCTAssertEqual(body["groupBy"] as? [String], ["DAY", "MODEL"])
    XCTAssertEqual(body["pageSize"] as? Int, 1000)
    XCTAssertEqual(body["startTime"] as? String, "2026-06-01T00:00:00Z")
    XCTAssertEqual(body["endTime"] as? String, "2026-07-01T00:00:00Z")
  }

  func testCostsAccountIDCannotChangeHostOrAddQuery() async throws {
    let requests = RequestRecorder()
    let client = FireworksCostClient(http: { request in
      requests.append(request)
      return (
        Data(
          #"{"rows":[],"subtotal":{"currencyCode":"USD","units":"0","nanos":0}}"#.utf8
        ),
        response(for: request, status: 200)
      )
    })

    _ = try await client.costs(
      account: FireworksAccount(
        resourceName: "accounts/other?leak=true#fragment",
        id: "other?leak=true#fragment"
      ),
      window: juneWindow(),
      scope: .account,
      credential: Secret("fw_secret")
    )

    let url = try XCTUnwrap(requests.requests[0].url)
    XCTAssertEqual(url.host, "api.fireworks.ai")
    XCTAssertNil(url.query)
    XCTAssertNil(url.fragment)
    XCTAssertEqual(
      url.pathComponents,
      ["/", "v1", "accounts", "other?leak=true#fragment", "usageCosts:query"]
    )
  }

  func testCostsRejectsUnsupportedCurrency() async {
    let client = FireworksCostClient(http: { request in
      return (
        Data(
          #"{"rows":[{"dimensions":{"startTime":"2026-06-01T00:00:00Z"},"subtotal":{"currencyCode":"EUR","units":"1","nanos":0}}],"subtotal":{"currencyCode":"USD","units":"1","nanos":0}}"#
            .utf8
        ),
        response(for: request, status: 200)
      )
    })

    await assertProviderThrows(
      try await client.costs(
        account: FireworksAccount(resourceName: "accounts/personal", id: "personal"),
        window: juneWindow(),
        scope: .account,
        credential: Secret("fw_secret")
      ),
      expected: .unsupportedCurrency
    )
  }

  func testCostsRejectsNanosOutsideMoneyRange() async {
    for nanos in [-1, 1_000_000_000] {
      let client = FireworksCostClient(http: { request in
        let body =
          #"{"rows":[{"dimensions":{"startTime":"2026-06-01T00:00:00Z"},"subtotal":{"currencyCode":"USD","units":"1","nanos":\#(nanos)}}],"subtotal":{"currencyCode":"USD","units":"1","nanos":0}}"#
        return (Data(body.utf8), response(for: request, status: 200))
      })

      await assertProviderThrows(
        try await client.costs(
          account: FireworksAccount(resourceName: "accounts/personal", id: "personal"),
          window: juneWindow(),
          scope: .account,
          credential: Secret("fw_secret")
        ),
        expected: .invalidResponse
      )
    }
  }

  func testCostsRejectsRepeatedPageTokenWithoutSentinelCollision() async {
    let requests = RequestRecorder()
    let client = FireworksCostClient(http: { request in
      requests.append(request)
      return (
        Data(
          #"{"rows":[],"nextPageToken":"<first>","subtotal":{"currencyCode":"USD","units":"0","nanos":0}}"#
            .utf8
        ),
        response(for: request, status: 200)
      )
    })

    await assertProviderThrows(
      try await client.costs(
        account: FireworksAccount(resourceName: "accounts/personal", id: "personal"),
        window: juneWindow(),
        scope: .account,
        credential: Secret("fw_secret")
      ),
      expected: .invalidResponse
    )
    XCTAssertEqual(requests.count, 2)
    let secondBody =
      try? JSONSerialization.jsonObject(
        with: requests.requests[1].httpBody!
      ) as? [String: Any]
    XCTAssertEqual(secondBody?["pageToken"] as? String, "<first>")
  }

  func testCostsRejectsMoreThanOneHundredPages() async {
    let requests = RequestRecorder()
    let client = FireworksCostClient(http: { request in
      requests.append(request)
      let body =
        #"{"rows":[],"nextPageToken":"page-\#(requests.count)","subtotal":{"currencyCode":"USD","units":"0","nanos":0}}"#
      return (Data(body.utf8), response(for: request, status: 200))
    })

    await assertProviderThrows(
      try await client.costs(
        account: FireworksAccount(resourceName: "accounts/personal", id: "personal"),
        window: juneWindow(),
        scope: .account,
        credential: Secret("fw_secret")
      ),
      expected: .invalidResponse
    )
    XCTAssertEqual(requests.count, 100)
  }

  func testCostsRejectsChangingQuerySubtotal() async {
    let requests = RequestRecorder()
    let client = FireworksCostClient(http: { request in
      requests.append(request)
      let body =
        requests.count == 1
        ? #"{"rows":[],"nextPageToken":"next","subtotal":{"currencyCode":"USD","units":"1","nanos":0}}"#
        : #"{"rows":[],"subtotal":{"currencyCode":"USD","units":"2","nanos":0}}"#
      return (Data(body.utf8), response(for: request, status: 200))
    })

    await assertProviderThrows(
      try await client.costs(
        account: FireworksAccount(resourceName: "accounts/personal", id: "personal"),
        window: juneWindow(),
        scope: .account,
        credential: Secret("fw_secret")
      ),
      expected: .invalidResponse
    )
  }

  func testCostsReportsOnlyStatusForAuthenticationFailures() async {
    for status in [401, 403] {
      let client = FireworksCostClient(http: { request in
        return (
          Data(#"{"error":"fw_secret private@example.test"}"#.utf8),
          response(for: request, status: status)
        )
      })

      await assertProviderThrows(
        try await client.costs(
          account: FireworksAccount(resourceName: "accounts/personal", id: "personal"),
          window: juneWindow(),
          scope: .account,
          credential: Secret("fw_secret")
        ),
        expected: .httpStatus(status)
      )
    }
  }

  func testCostsClampsRowsToWindowAndUsesNextDayAsExclusiveEnd() async throws {
    let client = FireworksCostClient(http: { request in
      return (
        Data(
          #"{"rows":[{"dimensions":{"startTime":"2026-05-31T12:00:00Z","model":"before"},"subtotal":{"currencyCode":"USD","units":"1","nanos":0}},{"dimensions":{"startTime":"2026-06-30T00:00:00Z","model":"last"},"subtotal":{"currencyCode":"USD","units":"2","nanos":0}}],"subtotal":{"currencyCode":"USD","units":"3","nanos":0}}"#
            .utf8
        ),
        response(for: request, status: 200)
      )
    })

    let result = try await client.costs(
      account: FireworksAccount(resourceName: "accounts/personal", id: "personal"),
      window: juneWindow(),
      scope: .account,
      credential: Secret("fw_secret")
    )

    XCTAssertEqual(result.rows[0].start, juneWindow().start)
    XCTAssertEqual(
      result.rows[0].end,
      ISO8601DateFormatter().date(from: "2026-06-01T12:00:00Z")
    )
    XCTAssertEqual(
      result.rows[1].start,
      ISO8601DateFormatter().date(from: "2026-06-30T00:00:00Z")
    )
    XCTAssertEqual(result.rows[1].end, juneWindow().end)
  }

  func testCostsChecksCancellationBeforeRequestingFirstPage() async {
    let requests = RequestRecorder()
    let client = FireworksCostClient(http: { request in
      requests.append(request)
      return (
        Data(
          #"{"rows":[],"subtotal":{"currencyCode":"USD","units":"0","nanos":0}}"#.utf8
        ),
        response(for: request, status: 200)
      )
    })
    let task = Task { () throws -> FireworksCostResult in
      withUnsafeCurrentTask { $0?.cancel() }
      return try await client.costs(
        account: FireworksAccount(resourceName: "accounts/personal", id: "personal"),
        window: juneWindow(),
        scope: .account,
        credential: Secret("fw_secret")
      )
    }

    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      XCTAssertTrue(true)
    } catch {
      XCTFail("Expected CancellationError, got \(error)")
    }
    XCTAssertEqual(requests.count, 0)
  }

  func testAccountsPaginatesAndReturnsOnlyResourceNames() async throws {
    let requests = RequestRecorder()
    let first = try fixtureData("fireworks-accounts-page")
    let client = FireworksCostClient(http: { request in
      requests.append(request)
      let body =
        requests.count == 1
        ? first
        : Data(#"{"accounts":[],"nextPageToken":""}"#.utf8)
      return (body, response(for: request, status: 200))
    })

    let accounts = try await client.accounts(credential: Secret("fw_secret"))

    XCTAssertEqual(
      accounts,
      [
        FireworksAccount(resourceName: "accounts/personal", id: "personal"),
        FireworksAccount(resourceName: "accounts/work", id: "work"),
      ]
    )
    XCTAssertEqual(requests.count, 2)
    XCTAssertTrue(
      requests.requests[1].url!.absoluteString.contains(
        "pageToken=accounts-page-2"
      )
    )
    XCTAssertEqual(
      requests.requests[0].value(forHTTPHeaderField: "Authorization"),
      "Bearer fw_secret"
    )
    let queryItems = try XCTUnwrap(
      URLComponents(
        url: requests.requests[0].url!,
        resolvingAgainstBaseURL: false
      )?.queryItems
    )
    XCTAssertEqual(queryItems.first { $0.name == "pageSize" }?.value, "200")
  }

  func testAccountsRejectsRepeatedPageToken() async {
    let requests = RequestRecorder()
    let client = FireworksCostClient(http: { request in
      requests.append(request)
      return (
        Data(#"{"accounts":[],"nextPageToken":"same"}"#.utf8),
        response(for: request, status: 200)
      )
    })

    await assertProviderThrows(
      try await client.accounts(credential: Secret("fw_secret")),
      expected: .invalidResponse
    )
    XCTAssertEqual(requests.count, 2)
  }

  func testAccountsAcceptsPageTokenMatchingFormerFirstPageSentinel() async throws {
    let requests = RequestRecorder()
    let client = FireworksCostClient(http: { request in
      requests.append(request)
      let body =
        requests.count == 1
        ? Data(#"{"accounts":[],"nextPageToken":"<first>"}"#.utf8)
        : Data(#"{"accounts":[]}"#.utf8)
      return (body, response(for: request, status: 200))
    })

    _ = try await client.accounts(credential: Secret("fw_secret"))

    XCTAssertEqual(requests.count, 2)
    let queryItems = try XCTUnwrap(
      URLComponents(
        url: requests.requests[1].url!,
        resolvingAgainstBaseURL: false
      )?.queryItems
    )
    XCTAssertEqual(queryItems.first { $0.name == "pageToken" }?.value, "<first>")
  }

  func testAccountsRejectsMalformedResourceName() async {
    let client = FireworksCostClient(http: { request in
      return (
        Data(#"{"accounts":[{"name":"projects/not-an-account"}]}"#.utf8),
        response(for: request, status: 200)
      )
    })

    await assertProviderThrows(
      try await client.accounts(credential: Secret("fw_secret")),
      expected: .invalidResponse
    )
  }

  func testAccountsRejectsMoreThanOneHundredPages() async {
    let requests = RequestRecorder()
    let client = FireworksCostClient(http: { request in
      requests.append(request)
      let body = #"{"accounts":[],"nextPageToken":"page-\#(requests.count)"}"#
      return (Data(body.utf8), response(for: request, status: 200))
    })

    await assertProviderThrows(
      try await client.accounts(credential: Secret("fw_secret")),
      expected: .invalidResponse
    )
    XCTAssertEqual(requests.count, 100)
  }

  func testAccountsChecksCancellationBeforeRequestingFirstPage() async {
    let requests = RequestRecorder()
    let client = FireworksCostClient(http: { request in
      requests.append(request)
      return (
        Data(#"{"accounts":[]}"#.utf8),
        response(for: request, status: 200)
      )
    })
    let task = Task { () throws -> [FireworksAccount] in
      withUnsafeCurrentTask { $0?.cancel() }
      return try await client.accounts(credential: Secret("fw_secret"))
    }

    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      XCTAssertTrue(true)
    } catch {
      XCTFail("Expected CancellationError, got \(error)")
    }
    XCTAssertEqual(requests.count, 0)
  }

  func testAccountsReportsOnlyStatusForHTTPFailure() async {
    let client = FireworksCostClient(http: { request in
      return (
        Data(#"{"error":"fw_secret private@example.test"}"#.utf8),
        response(for: request, status: 401)
      )
    })

    await assertProviderThrows(
      try await client.accounts(credential: Secret("fw_secret")),
      expected: .httpStatus(401)
    )
  }
}
