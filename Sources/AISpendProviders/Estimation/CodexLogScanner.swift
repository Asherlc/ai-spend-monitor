import AISpendCore
import Foundation

public struct CodexLogScanner: Sendable {
  private let scanner: LocalLogScanner

  public init(
    priceCatalog: PriceCatalog,
    calendar: Calendar = .current,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) {
    self.init(
      sessionRoots: [homeDirectory.appendingPathComponent(".codex/sessions")],
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
      provider: .openAI,
      sessionRoots: sessionRoots,
      priceCatalog: priceCatalog,
      calendar: calendar,
      candidateLine: {
        $0.range(of: Self.turnContextMarker) != nil
          || $0.range(of: Self.tokenCountMarker) != nil
      },
      parser: Self.parse
    )
  }

  public func scan(window: MonthWindow, fetchedAt: Date) throws -> LocalLogScanResult {
    try scanner.scan(window: window, fetchedAt: fetchedAt)
  }

  private static let turnContextMarker = Data(#""turn_context""#.utf8)
  private static let tokenCountMarker = Data(#""token_count""#.utf8)

  private static func parse(
    _ object: [String: Any],
    context: inout LogParseContext
  ) -> LocalUsage? {
    if object["type"] as? String == "turn_context",
      let payload = object["payload"] as? [String: Any],
      let model = payload["model"] as? String
    {
      context.model = model
      return nil
    }
    guard
      object["type"] as? String == "event_msg",
      let timestampValue = object["timestamp"] as? String,
      let timestamp = context.parseTimestamp(timestampValue),
      let payload = object["payload"] as? [String: Any],
      payload["type"] as? String == "token_count",
      let model = payload["model"] as? String ?? context.model,
      let info = payload["info"] as? [String: Any],
      let usage = info["last_token_usage"] as? [String: Any],
      let totalInput = integer(usage["input_tokens"]),
      let output = integer(usage["output_tokens"])
    else {
      return nil
    }
    let cachedInput = integer(usage["cached_input_tokens"]) ?? 0
    guard totalInput >= cachedInput, cachedInput >= 0, output >= 0 else {
      return nil
    }
    let eventID =
      string(in: object, keys: ["event_id", "id"])
      ?? string(in: payload, keys: ["event_id", "id"])
      ?? [
        "position:\(context.relativePath):\(context.lineNumber)",
        "timestamp:\(timestampValue)",
        "model:\(model)",
        "tokens:\(totalInput):\(cachedInput):\(output)",
      ].joined(separator: "|")
    return LocalUsage(
      eventID: eventID,
      timestamp: timestamp,
      model: model,
      inputTokens: totalInput - cachedInput,
      cachedInputTokens: cachedInput,
      outputTokens: output
    )
  }
}
