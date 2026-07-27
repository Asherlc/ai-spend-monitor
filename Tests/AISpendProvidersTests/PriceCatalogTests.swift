import AISpendCore
import Foundation
import XCTest

@testable import AISpendProviders

final class PriceCatalogTests: XCTestCase {
  func testBundledCatalogUsesExactVerifiedRatesIncludingClaudeCacheWrites() throws {
    let usage = LocalUsage(
      eventID: "event-1",
      timestamp: Date(timeIntervalSince1970: 0),
      model: "claude-sonnet-4-5",
      inputTokens: 1_000_000,
      cacheCreationInputTokens: 100_000,
      cachedInputTokens: 200_000,
      outputTokens: 100_000
    )

    let amount = try PriceCatalog.bundled().estimate(usage)

    XCTAssertEqual(amount, Money(Decimal(string: "4.935")!))
  }

  func testUnknownModelIsUnavailableInsteadOfZeroCost() throws {
    let usage = LocalUsage(
      eventID: "event-unknown",
      timestamp: Date(timeIntervalSince1970: 0),
      model: "unpriced-model",
      inputTokens: 1,
      cachedInputTokens: 0,
      outputTokens: 0
    )

    XCTAssertThrowsError(try PriceCatalog.bundled().estimate(usage)) {
      XCTAssertEqual($0 as? PriceCatalogError, .unknownModel("unpriced-model"))
    }
  }
}
