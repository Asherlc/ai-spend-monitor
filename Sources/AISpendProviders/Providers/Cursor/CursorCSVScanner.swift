import AISpendCore
import Foundation

struct CursorCSVScanResult: Sendable {
  let records: [SpendRecord]
  let sourceID: String
}

struct CursorCSVScanner: Sendable {
  private static let filePrefix = "team-usage-events-"
  private static let sourceID = "cursor-dashboard-export"

  private let downloadsDirectory: URL
  private let fingerprinter: AccountFingerprinter
  private let calendar: Calendar

  init(
    downloadsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Downloads"),
    fingerprinter: AccountFingerprinter = .production,
    calendar: Calendar = .current
  ) {
    self.downloadsDirectory = downloadsDirectory.standardizedFileURL
    self.fingerprinter = fingerprinter
    self.calendar = calendar
  }

  func scan(window: MonthWindow, fetchedAt: Date) throws -> CursorCSVScanResult? {
    try Task.checkCancellation()
    guard let export = try latestExport() else {
      return nil
    }
    let rows = try CSVRows.parse(Data(contentsOf: export))
    guard let header = rows.first else {
      return nil
    }
    let columns = Dictionary(uniqueKeysWithValues: header.enumerated().map { ($1, $0) })
    guard
      let dateColumn = columns["Date"],
      let modelColumn = columns["Model"],
      let costColumn = columns["Cost"]
    else {
      return nil
    }
    let teamID = teamIdentifier(from: export.lastPathComponent)
    let accountFingerprint = try fingerprinter.fingerprint(
      identity: Secret(teamID),
      namespace: "cursor-team"
    )
    let parseContext = LogParseContext(relativePath: export.lastPathComponent)
    var totals: [ModelDay: Decimal] = [:]
    for row in rows.dropFirst() {
      try Task.checkCancellation()
      guard
        row.indices.contains(dateColumn),
        row.indices.contains(modelColumn),
        row.indices.contains(costColumn),
        let timestamp = parseContext.parseTimestamp(row[dateColumn]),
        window.contains(timestamp),
        let cost = Decimal(
          string: row[costColumn],
          locale: Locale(identifier: "en_US_POSIX")
        ),
        cost >= 0
      else {
        continue
      }
      let model = row[modelColumn].trimmingCharacters(in: .whitespacesAndNewlines)
      guard !model.isEmpty else {
        continue
      }
      totals[
        ModelDay(
          start: calendar.startOfDay(for: timestamp),
          model: model
        ),
        default: 0
      ] += cost
    }

    let records = try totals.sorted(by: { $0.key < $1.key }).compactMap {
      day, amount -> SpendRecord? in
      guard amount > 0,
        let intervalEnd = calendar.date(byAdding: .day, value: 1, to: day.start)
      else {
        return nil
      }
      let observationID = stableIdentifier([
        Self.sourceID,
        accountFingerprint,
        String(day.start.timeIntervalSince1970),
        day.model,
      ])
      return try SpendRecord(
        id: observationID,
        provider: .cursor,
        accountFingerprint: accountFingerprint,
        model: day.model,
        intervalStart: day.start,
        intervalEnd: intervalEnd,
        amount: Money(amount),
        quality: .actual,
        sourceID: Self.sourceID,
        observationID: observationID,
        fetchedAt: fetchedAt,
        estimate: nil
      )
    }
    return CursorCSVScanResult(records: records, sourceID: Self.sourceID)
  }

  private func latestExport() throws -> URL? {
    let keys: Set<URLResourceKey> = [
      .contentModificationDateKey,
      .isRegularFileKey,
      .isSymbolicLinkKey,
    ]
    let candidates = try FileManager.default.contentsOfDirectory(
      at: downloadsDirectory,
      includingPropertiesForKeys: Array(keys),
      options: [.skipsHiddenFiles]
    ).compactMap { url -> (URL, Date)? in
      guard
        url.lastPathComponent.hasPrefix(Self.filePrefix),
        url.pathExtension.lowercased() == "csv",
        let values = try? url.resourceValues(forKeys: keys),
        values.isRegularFile == true,
        values.isSymbolicLink != true
      else {
        return nil
      }
      return (url, values.contentModificationDate ?? .distantPast)
    }
    return candidates.max {
      if $0.1 != $1.1 {
        return $0.1 < $1.1
      }
      return $0.0.lastPathComponent < $1.0.lastPathComponent
    }?.0
  }

  private func teamIdentifier(from fileName: String) -> String {
    let remainder =
      fileName
      .dropFirst(Self.filePrefix.count)
      .dropLast(".csv".count)
    return remainder.split(separator: "-", maxSplits: 1).first.map(String.init) ?? "unknown"
  }
}

private struct ModelDay: Hashable, Comparable {
  let start: Date
  let model: String

  static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.start != rhs.start {
      return lhs.start < rhs.start
    }
    return lhs.model < rhs.model
  }
}

private enum CSVRows {
  static func parse(_ data: Data) throws -> [[String]] {
    guard let text = String(data: data, encoding: .utf8) else {
      throw SourceHostError.sourceUnavailable
    }
    var rows: [[String]] = []
    var row: [String] = []
    var field = ""
    var index = text.startIndex
    var quoted = false
    while index < text.endIndex {
      let character = text[index]
      if quoted {
        if character == "\"" {
          let next = text.index(after: index)
          if next < text.endIndex, text[next] == "\"" {
            field.append("\"")
            index = next
          } else {
            quoted = false
          }
        } else {
          field.append(character)
        }
      } else {
        switch character {
        case "\"":
          quoted = true
        case ",":
          row.append(field)
          field = ""
        case "\n":
          row.append(field.trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
          rows.append(row)
          row = []
          field = ""
        default:
          field.append(character)
        }
      }
      index = text.index(after: index)
    }
    guard !quoted else {
      throw SourceHostError.sourceUnavailable
    }
    if !field.isEmpty || !row.isEmpty {
      row.append(field.trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
      rows.append(row)
    }
    return rows
  }
}
