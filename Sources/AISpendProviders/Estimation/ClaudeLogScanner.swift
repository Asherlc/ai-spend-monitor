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
      candidateLine: { $0.range(of: Self.assistantMarker) != nil },
      parser: Self.parse
    )
  }

  public func scan(window: MonthWindow, fetchedAt: Date) throws -> LocalLogScanResult {
    try scanner.scan(window: window, fetchedAt: fetchedAt)
  }

  private static let assistantMarker = Data(#""assistant""#.utf8)

  private static func parse(
    _ object: [String: Any],
    context: inout LogParseContext
  ) -> LocalUsage? {
    guard
      object["type"] as? String == "assistant",
      let timestampValue = object["timestamp"] as? String,
      let timestamp = context.parseTimestamp(timestampValue),
      let message = object["message"] as? [String: Any],
      let model = message["model"] as? String,
      let usage = message["usage"] as? [String: Any],
      let input = integer(usage["input_tokens"]),
      let output = integer(usage["output_tokens"])
    else {
      return nil
    }
    let eventID: String
    if let requestID = object["requestId"] as? String,
      let messageID = message["id"] as? String
    {
      eventID = "request:\(requestID)|message:\(messageID)"
    } else if let messageID = message["id"] as? String {
      eventID = "message:\(messageID)"
    } else {
      guard let rowID = string(in: object, keys: ["uuid", "event_id", "id"]) else {
        return nil
      }
      eventID = "row:\(rowID)"
    }
    let cacheCreation = integer(usage["cache_creation_input_tokens"]) ?? 0
    let cacheCreationDetails = usage["cache_creation"] as? [String: Any]
    let cacheCreation5m =
      integer(cacheCreationDetails?["ephemeral_5m_input_tokens"]) ?? cacheCreation
    let cacheCreation1h =
      integer(cacheCreationDetails?["ephemeral_1h_input_tokens"]) ?? 0
    let cacheRead = integer(usage["cache_read_input_tokens"]) ?? 0
    guard
      cacheCreation5m + cacheCreation1h == cacheCreation,
      [input, cacheCreation5m, cacheCreation1h, cacheRead, output].allSatisfy({ $0 >= 0 })
    else {
      return nil
    }
    return LocalUsage(
      eventID: eventID,
      timestamp: timestamp,
      model: model,
      inputTokens: input,
      cacheCreation5mInputTokens: cacheCreation5m,
      cacheCreation1hInputTokens: cacheCreation1h,
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
