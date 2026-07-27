import Foundation
import XCTest

@testable import AISpendProviders

final class HTTPClientTests: XCTestCase {
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
