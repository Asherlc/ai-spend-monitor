import XCTest

@testable import AISpendProviders

final class RedactorTests: XCTestCase {
  func testRemovesSensitiveDiagnosticValues() {
    let sensitiveValues = [
      "Bearer eyJhbGciOiJIUzI1NiJ9.payload.signature",
      "session-cookie-value",
      "secret@example.com",
      "sk-ant-admin01-secretvalue",
    ]
    let input = """
      Authorization: \(sensitiveValues[0])
      Cookie: \(sensitiveValues[1])
      email=\(sensitiveValues[2])
      key=\(sensitiveValues[3])
      """

    let output = Redactor().redact(input)

    for value in sensitiveValues {
      XCTAssertFalse(output.contains(value))
    }
    XCTAssertFalse(output.contains("eyJhbGciOi"))
    XCTAssertFalse(output.contains("secret@example.com"))
    XCTAssertFalse(output.contains("sk-ant-admin01-secretvalue"))
  }
}
