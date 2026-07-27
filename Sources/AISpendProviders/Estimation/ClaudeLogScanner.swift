import AISpendCore
import Foundation

public struct ClaudeLogScanner: Sendable {
  private let scanner: LocalLogScanner

  public init(
    priceCatalog: PriceCatalog,
    calendar: Calendar = .current,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) {
    self.init(
      sessionRoots: [homeDirectory.appendingPathComponent(".claude/projects")],
      priceCatalog: priceCatalog,
      calendar: calendar
    )
  }

  init(
    sessionRoots: [URL],
    priceCatalog: PriceCatalog,
    calendar: Calendar
  ) {
    scanner = LocalLogScanner(
      provider: .claude,
      sessionRoots: sessionRoots,
      priceCatalog: priceCatalog,
      calendar: calendar,
      parser: Self.parse
    )
  }

  public func scan(window: MonthWindow, fetchedAt: Date) throws -> LocalLogScanResult {
    try scanner.scan(window: window, fetchedAt: fetchedAt)
  }

  private static func parse(
    _ object: [String: Any],
    context _: inout String?
  ) -> LocalUsage? {
    guard
      object["type"] as? String == "assistant",
      let eventID = string(in: object, keys: ["uuid", "event_id", "id"]),
      let timestampValue = object["timestamp"] as? String,
      let timestamp = ISO8601DateFormatter().date(from: timestampValue),
      let message = object["message"] as? [String: Any],
      let model = message["model"] as? String,
      let usage = message["usage"] as? [String: Any],
      let input = integer(usage["input_tokens"]),
      let output = integer(usage["output_tokens"])
    else {
      return nil
    }
    let cacheCreation = integer(usage["cache_creation_input_tokens"]) ?? 0
    let cacheRead = integer(usage["cache_read_input_tokens"]) ?? 0
    guard [input, cacheCreation, cacheRead, output].allSatisfy({ $0 >= 0 }) else {
      return nil
    }
    return LocalUsage(
      eventID: eventID,
      timestamp: timestamp,
      model: model,
      inputTokens: input,
      cacheCreationInputTokens: cacheCreation,
      cachedInputTokens: cacheRead,
      outputTokens: output
    )
  }
}

func string(in object: [String: Any], keys: [String]) -> String? {
  keys.lazy.compactMap { object[$0] as? String }.first
}

func integer(_ value: Any?) -> Int? {
  if let value = value as? Int {
    return value
  }
  if let value = value as? NSNumber {
    return value.intValue
  }
  return nil
}
