import AISpendCore
import Foundation
import XCTest

@testable import AISpendProviders

final class FireworksCostClientTests: XCTestCase {
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
