import AISpendCore
import CryptoKit
import Darwin
import Foundation

public struct LocalUsage: Hashable, Sendable {
  public let eventID: String
  public let timestamp: Date
  public let model: String
  public let inputTokens: Int
  public let cacheCreation5mInputTokens: Int
  public let cacheCreation1hInputTokens: Int
  public let cachedInputTokens: Int
  public let outputTokens: Int

  public init(
    eventID: String,
    timestamp: Date,
    model: String,
    inputTokens: Int,
    cacheCreation5mInputTokens: Int = 0,
    cacheCreation1hInputTokens: Int = 0,
    cachedInputTokens: Int,
    outputTokens: Int
  ) {
    self.eventID = eventID
    self.timestamp = timestamp
    self.model = model
    self.inputTokens = inputTokens
    self.cacheCreation5mInputTokens = cacheCreation5mInputTokens
    self.cacheCreation1hInputTokens = cacheCreation1hInputTokens
    self.cachedInputTokens = cachedInputTokens
    self.outputTokens = outputTokens
  }
}

public enum LocalLogDiagnostic: Hashable, Sendable {
  case malformedLine(file: String, line: Int)
  case sourceUnavailable(file: String)
  case unavailableEstimate(model: String)
}

public struct LocalLogScanResult: Sendable {
  public let records: [SpendRecord]
  public let diagnostics: [LocalLogDiagnostic]

  public init(records: [SpendRecord], diagnostics: [LocalLogDiagnostic]) {
    self.records = records
    self.diagnostics = diagnostics
  }
}

struct LocalLogScanner {
  typealias UsageParser = @Sendable ([String: Any], inout LogParseContext) -> LocalUsage?
  typealias CandidateLine = @Sendable (Data) -> Bool

  let provider: ProviderID
  let sessionRoots: [URL]
  let priceCatalog: PriceCatalog
  let calendar: Calendar
  let candidateLine: CandidateLine
  let parser: UsageParser

  init(
    provider: ProviderID,
    sessionRoots: [URL],
    priceCatalog: PriceCatalog,
    calendar: Calendar,
    candidateLine: @escaping CandidateLine = { _ in true },
    parser: @escaping UsageParser
  ) {
    self.provider = provider
    self.sessionRoots = sessionRoots
    self.priceCatalog = priceCatalog
    self.calendar = calendar
    self.candidateLine = candidateLine
    self.parser = parser
  }

  func scan(window: MonthWindow, fetchedAt: Date) throws -> LocalLogScanResult {
    try Task.checkCancellation()
    var diagnostics: [LocalLogDiagnostic] = []
    var usageByID: [BilledUsageKey: LocalUsage] = [:]

    for file in try candidateFiles(window: window, diagnostics: &diagnostics) {
      try Task.checkCancellation()
      do {
        var parserContext = LogParseContext(relativePath: relativePath(file.url, to: file.root))
        try scan(file: file.url, relativeTo: file.root) { data, lineNumber in
          parserContext.lineNumber = lineNumber
          guard data.isEmpty || candidateLine(data) else {
            return
          }
          guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any]
          else {
            diagnostics.append(
              .malformedLine(file: file.url.lastPathComponent, line: lineNumber)
            )
            return
          }
          guard
            let usage = parser(dictionary, &parserContext),
            window.contains(usage.timestamp)
          else {
            return
          }
          let key = BilledUsageKey(eventID: usage.eventID, model: usage.model)
          usageByID[key] = merge(usageByID[key], with: usage)
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        diagnostics.append(.sourceUnavailable(file: file.url.lastPathComponent))
      }
    }

    let groups = Dictionary(grouping: usageByID.values) { usage in
      UsageDay(
        start: calendar.startOfDay(for: usage.timestamp),
        model: usage.model
      )
    }
    var records: [SpendRecord] = []
    for (day, usages) in groups.sorted(by: { $0.key < $1.key }) {
      let aggregate = LocalUsage(
        eventID: usages.map(\.eventID).sorted().joined(separator: ","),
        timestamp: day.start,
        model: day.model,
        inputTokens: usages.reduce(0) { $0 + $1.inputTokens },
        cacheCreation5mInputTokens: usages.reduce(0) { $0 + $1.cacheCreation5mInputTokens },
        cacheCreation1hInputTokens: usages.reduce(0) { $0 + $1.cacheCreation1hInputTokens },
        cachedInputTokens: usages.reduce(0) { $0 + $1.cachedInputTokens },
        outputTokens: usages.reduce(0) { $0 + $1.outputTokens }
      )
      let amount: Money
      do {
        amount = try priceCatalog.estimate(aggregate)
      } catch PriceCatalogError.unknownModel {
        diagnostics.append(.unavailableEstimate(model: day.model))
        continue
      }
      guard let intervalEnd = calendar.date(byAdding: .day, value: 1, to: day.start) else {
        continue
      }
      let observationID = Self.observationID(
        provider: provider,
        model: day.model,
        day: day.start,
        eventIDs: usages.map(\.eventID)
      )
      records.append(
        try SpendRecord(
          id: observationID,
          provider: provider,
          accountFingerprint: "local",
          model: day.model,
          intervalStart: day.start,
          intervalEnd: intervalEnd,
          amount: amount,
          quality: .estimated,
          sourceID: "\(provider.rawValue)-local-logs",
          observationID: observationID,
          fetchedAt: fetchedAt,
          estimate: EstimateMetadata(
            inputTokens: aggregate.inputTokens,
            cacheCreation5mInputTokens: aggregate.cacheCreation5mInputTokens,
            cacheCreation1hInputTokens: aggregate.cacheCreation1hInputTokens,
            cachedInputTokens: aggregate.cachedInputTokens,
            outputTokens: aggregate.outputTokens,
            catalogVersion: priceCatalog.version
          )
        )
      )
    }

    return LocalLogScanResult(
      records: records,
      diagnostics: diagnostics.sorted(by: diagnosticOrder)
    )
  }

  private func candidateFiles(
    window: MonthWindow,
    diagnostics: inout [LocalLogDiagnostic]
  ) throws -> [(root: URL, url: URL)] {
    let keys: [URLResourceKey] = [
      .contentModificationDateKey,
      .isDirectoryKey,
      .isRegularFileKey,
      .isSymbolicLinkKey,
    ]
    var files: [(root: URL, url: URL)] = []
    for root in sessionRoots.map(\.standardizedFileURL) {
      guard
        let enumerator = FileManager.default.enumerator(
          at: root,
          includingPropertiesForKeys: keys,
          options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
      else {
        diagnostics.append(.sourceUnavailable(file: root.lastPathComponent))
        continue
      }
      while let item = enumerator.nextObject() as? URL {
        try Task.checkCancellation()
        guard let values = try? item.resourceValues(forKeys: Set(keys)) else {
          diagnostics.append(.sourceUnavailable(file: item.lastPathComponent))
          enumerator.skipDescendants()
          continue
        }
        if values.isSymbolicLink == true {
          enumerator.skipDescendants()
          continue
        }
        guard values.isRegularFile == true, item.pathExtension == "jsonl",
          let modified = values.contentModificationDate,
          modified >= window.start
        else {
          continue
        }
        files.append((root, item.standardizedFileURL))
      }
    }
    return files.sorted { lhs, rhs in
      if lhs.root.path != rhs.root.path {
        return lhs.root.path < rhs.root.path
      }
      return lhs.url.path < rhs.url.path
    }
  }

  private func scan(
    file: URL,
    relativeTo root: URL,
    process: (Data, Int) -> Void
  ) throws {
    let rootComponents = root.standardizedFileURL.pathComponents
    let fileComponents = file.standardizedFileURL.pathComponents
    guard fileComponents.starts(with: rootComponents) else {
      throw SourceHostError.pathNotAllowed
    }
    let relativeComponents = Array(fileComponents.dropFirst(rootComponents.count))
    let descriptor = try SecureFileReader.openFile(
      root: root,
      relativeComponents: relativeComponents
    )
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    var buffer = Data()
    var lineNumber = 0
    var discardingOversizedLine = false
    let maximumLineBytes = 1_048_576

    while true {
      try Task.checkCancellation()
      let chunk = try handle.read(upToCount: 65_536) ?? Data()
      if chunk.isEmpty {
        if discardingOversizedLine {
          lineNumber += 1
          process(Data(), lineNumber)
        } else if !buffer.isEmpty {
          lineNumber += 1
          process(buffer, lineNumber)
        }
        break
      }
      buffer.append(chunk)
      var lineStart = buffer.startIndex
      while lineStart < buffer.endIndex,
        let newline = buffer[lineStart...].firstIndex(of: 0x0A)
      {
        lineNumber += 1
        let line = buffer[lineStart..<newline]
        if discardingOversizedLine {
          discardingOversizedLine = false
          process(Data(), lineNumber)
        } else if !line.isEmpty {
          process(Data(line), lineNumber)
        }
        lineStart = buffer.index(after: newline)
      }
      if lineStart > buffer.startIndex {
        buffer.removeSubrange(buffer.startIndex..<lineStart)
      }
      if buffer.count > maximumLineBytes {
        discardingOversizedLine = true
        buffer.removeAll(keepingCapacity: true)
      }
    }
  }

  private static func observationID(
    provider: ProviderID,
    model: String,
    day: Date,
    eventIDs: [String]
  ) -> String {
    let dayValue = ISO8601DateFormatter().string(from: day)
    let input = ([provider.rawValue, model, dayValue] + eventIDs.sorted())
      .joined(separator: "\u{1f}")
    let digest = SHA256.hash(data: Data(input.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  private func merge(_ existing: LocalUsage?, with incoming: LocalUsage) -> LocalUsage {
    guard let existing else {
      return incoming
    }
    return LocalUsage(
      eventID: incoming.eventID,
      timestamp: max(existing.timestamp, incoming.timestamp),
      model: incoming.model,
      inputTokens: max(existing.inputTokens, incoming.inputTokens),
      cacheCreation5mInputTokens: max(
        existing.cacheCreation5mInputTokens,
        incoming.cacheCreation5mInputTokens
      ),
      cacheCreation1hInputTokens: max(
        existing.cacheCreation1hInputTokens,
        incoming.cacheCreation1hInputTokens
      ),
      cachedInputTokens: max(existing.cachedInputTokens, incoming.cachedInputTokens),
      outputTokens: max(existing.outputTokens, incoming.outputTokens)
    )
  }

  private func relativePath(_ file: URL, to root: URL) -> String {
    let rootComponents = root.standardizedFileURL.pathComponents
    return file.standardizedFileURL.pathComponents
      .dropFirst(rootComponents.count)
      .joined(separator: "/")
  }
}

struct LogParseContext {
  var model: String?
  let relativePath: String
  var lineNumber = 0
  private let timestampFormatter = ISO8601DateFormatter()

  func parseTimestamp(_ value: String) -> Date? {
    timestampFormatter.date(from: value)
  }
}

private struct BilledUsageKey: Hashable {
  let eventID: String
  let model: String
}

private struct UsageDay: Hashable, Comparable {
  let start: Date
  let model: String

  static func < (lhs: UsageDay, rhs: UsageDay) -> Bool {
    if lhs.start != rhs.start {
      return lhs.start < rhs.start
    }
    return lhs.model < rhs.model
  }
}

private func diagnosticOrder(
  _ lhs: LocalLogDiagnostic,
  _ rhs: LocalLogDiagnostic
) -> Bool {
  String(describing: lhs) < String(describing: rhs)
}
