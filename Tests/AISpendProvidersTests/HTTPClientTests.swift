import Foundation
import XCTest

@testable import AISpendProviders

final class HTTPClientTests: XCTestCase {
  override func tearDown() {
    TestURLProtocol.state.reset()
    super.tearDown()
  }

  func testRejectsNonHTTPSRequests() async {
    let request = URLRequest(url: URL(string: "http://api.openai.com/v1/usage")!)

    await assertThrowsErrorAsync(try await HTTPClient().data(for: request)) {
      XCTAssertEqual($0 as? SourceHostError, .domainNotAllowed)
    }
  }

  func testRejectsHostOutsideExactAllowlist() async {
    let request = URLRequest(url: URL(string: "https://api.openai.com.attacker.test/v1")!)

    await assertThrowsErrorAsync(try await HTTPClient().data(for: request)) {
      XCTAssertEqual($0 as? SourceHostError, .domainNotAllowed)
    }
  }

  func testAllowedRequestUsesNoCacheAndTwentySecondTimeout() async throws {
    TestURLProtocol.state.setMode(.success)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TestURLProtocol.self]
    let client = HTTPClient(configuration: configuration)
    let request = URLRequest(url: URL(string: "https://api.openai.com/v1/usage")!)

    let (data, response) = try await client.data(for: request)

    XCTAssertEqual(data, Data("ok".utf8))
    XCTAssertEqual(response.statusCode, 200)
    let received = try XCTUnwrap(TestURLProtocol.state.lastRequest)
    XCTAssertEqual(received.timeoutInterval, 20)
    XCTAssertEqual(received.cachePolicy, .reloadIgnoringLocalCacheData)
  }

  func testURLSessionDoesNotFollowRedirectOutsideExactAllowlist() async throws {
    let attackerURL = URL(string: "https://attacker.test/steal")!
    TestURLProtocol.state.setMode(.redirect(attackerURL))
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TestURLProtocol.self]
    let client = HTTPClient(configuration: configuration)
    var request = URLRequest(url: URL(string: "https://api.openai.com/start")!)
    request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")

    _ = try? await client.data(for: request)

    XCTAssertEqual(
      TestURLProtocol.state.requestedURLs,
      [URL(string: "https://api.openai.com/start")!]
    )
  }

  func testRedirectDelegateRejectsRedirectOutsideExactAllowlist() {
    var request = URLRequest(url: URL(string: "https://attacker.test/steal")!)
    request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")

    let redirected = HTTPRedirectDelegate().validatedRedirectRequest(request)

    XCTAssertNil(redirected)
  }

  func testRedirectDelegateStripsSensitiveHeadersFromAllowedRedirect() throws {
    var request = URLRequest(url: URL(string: "https://api.cursor.com/usage")!)
    request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
    request.setValue("session=secret", forHTTPHeaderField: "Cookie")
    request.setValue("admin-secret", forHTTPHeaderField: "X-API-Key")
    request.setValue("team-secret", forHTTPHeaderField: "X-Cursor-Team-Id")
    request.setValue("safe", forHTTPHeaderField: "Accept")

    let redirected = try XCTUnwrap(
      HTTPRedirectDelegate().validatedRedirectRequest(request)
    )

    XCTAssertNil(redirected.value(forHTTPHeaderField: "Authorization"))
    XCTAssertNil(redirected.value(forHTTPHeaderField: "Cookie"))
    XCTAssertNil(redirected.value(forHTTPHeaderField: "X-API-Key"))
    XCTAssertNil(redirected.value(forHTTPHeaderField: "X-Cursor-Team-Id"))
    XCTAssertEqual(redirected.value(forHTTPHeaderField: "Accept"), "safe")
  }

  func testCancellationIsRethrownWithoutWrapping() async throws {
    TestURLProtocol.state.setMode(.pending)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TestURLProtocol.self]
    let client = HTTPClient(configuration: configuration)
    let request = URLRequest(url: URL(string: "https://api.openai.com/v1/usage")!)
    let task = Task { try await client.data(for: request) }
    for _ in 0..<100 where TestURLProtocol.state.lastRequest == nil {
      await Task.yield()
    }

    task.cancel()

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

private func assertThrowsErrorAsync<T>(
  _ expression: @autoclosure () async throws -> T,
  _ verify: (Error) -> Void,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await expression()
    XCTFail("Expected error", file: file, line: line)
  } catch {
    verify(error)
  }
}

private final class TestURLProtocol: URLProtocol {
  static let state = TestURLProtocolState()

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    Self.state.record(request)
    if case .pending = Self.state.mode {
      return
    }
    if case .redirect(let url) = Self.state.mode {
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 302,
        httpVersion: nil,
        headerFields: ["Location": url.absoluteString]
      )!
      var redirectedRequest = URLRequest(url: url)
      redirectedRequest.setValue(
        request.value(forHTTPHeaderField: "Authorization"),
        forHTTPHeaderField: "Authorization"
      )
      client?.urlProtocol(
        self,
        wasRedirectedTo: redirectedRequest,
        redirectResponse: response
      )
      client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
      return
    }
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: 200,
      httpVersion: nil,
      headerFields: nil
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data("ok".utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

private final class TestURLProtocolState: @unchecked Sendable {
  enum Mode {
    case success
    case redirect(URL)
    case pending
  }

  private let lock = NSLock()
  private var requests: [URLRequest] = []
  private var storedMode: Mode = .success

  var lastRequest: URLRequest? {
    lock.withLock { requests.last }
  }

  var requestedURLs: [URL] {
    lock.withLock { requests.compactMap(\.url) }
  }

  var mode: Mode {
    lock.withLock { storedMode }
  }

  func setMode(_ mode: Mode) {
    lock.withLock {
      requests = []
      storedMode = mode
    }
  }

  func record(_ request: URLRequest) {
    lock.withLock { requests.append(request) }
  }

  func reset() {
    lock.withLock {
      requests = []
      storedMode = .success
    }
  }
}
