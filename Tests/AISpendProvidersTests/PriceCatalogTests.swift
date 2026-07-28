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
      cacheCreation5mInputTokens: 60_000,
      cacheCreation1hInputTokens: 40_000,
      cachedInputTokens: 200_000,
      outputTokens: 100_000
    )

    let amount = try PriceCatalog.bundled().estimate(usage)

    XCTAssertEqual(amount, Money(Decimal(string: "5.025")!))
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

  func testModelWithoutPublishedCacheWriteRateRejectsCacheWriteUsage() throws {
    let usage = LocalUsage(
      eventID: "codex-cache-write",
      timestamp: Date(timeIntervalSince1970: 0),
      model: "gpt-5.3-codex",
      inputTokens: 0,
      cacheCreation5mInputTokens: 1,
      cachedInputTokens: 0,
      outputTokens: 0
    )

    XCTAssertThrowsError(try PriceCatalog.bundled().estimate(usage)) {
      XCTAssertEqual($0 as? PriceCatalogError, .invalidUsage)
    }
  }

  func testCatalogPricesCurrentClaudeModelsFromOfficialRateCard() throws {
    let cases: [(String, String)] = [
      ("claude-fable-5", "93.50"),
      ("claude-opus-4-8", "46.75"),
      ("claude-sonnet-5", "18.70"),
      ("claude-haiku-4-5-20251001", "9.35"),
    ]

    for (model, expected) in cases {
      let usage = LocalUsage(
        eventID: model,
        timestamp: Date(timeIntervalSince1970: 0),
        model: model,
        inputTokens: 1_000_000,
        cacheCreation5mInputTokens: 1_000_000,
        cacheCreation1hInputTokens: 1_000_000,
        cachedInputTokens: 1_000_000,
        outputTokens: 1_000_000
      )

      XCTAssertEqual(
        try PriceCatalog.bundled().estimate(usage),
        Money(Decimal(string: expected)!),
        model
      )
    }
  }

  func testCatalogPricesCurrentCodexModelsFromOfficialCreditRateCard() throws {
    let cases: [(String, String)] = [
      ("gpt-5.4", "17.75"),
      ("gpt-5.5", "35.50"),
      ("gpt-5.6-sol", "35.50"),
      ("gpt-5.6-terra", "17.75"),
      ("gpt-5.6-luna", "7.10"),
      ("codex-auto-review", "15.925"),
    ]

    for (model, expected) in cases {
      let usage = LocalUsage(
        eventID: model,
        timestamp: Date(timeIntervalSince1970: 0),
        model: model,
        inputTokens: 1_000_000,
        cachedInputTokens: 1_000_000,
        outputTokens: 1_000_000
      )

      XCTAssertEqual(
        try PriceCatalog.bundled().estimate(usage),
        Money(Decimal(string: expected)!),
        model
      )
    }
  }
}
