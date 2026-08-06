import AISpendCore
import Foundation

public struct CodexLogScanner: Sendable {
  private let sessionRoots: [URL]
  private let priceCatalog: PriceCatalog
  private let calendar: Calendar
  private let beforeLineageScan: @Sendable () throws -> Void
  private let afterLineageScan: @Sendable () throws -> Void
  private let onLineageDeepScan: @Sendable (URL) -> Void

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
    calendar: Calendar,
    beforeLineageScan: @escaping @Sendable () throws -> Void = {},
    afterLineageScan: @escaping @Sendable () throws -> Void = {},
    onLineageDeepScan: @escaping @Sendable (URL) -> Void = { _ in }
  ) {
    self.sessionRoots = sessionRoots
    self.priceCatalog = priceCatalog
    self.calendar = calendar
    self.beforeLineageScan = beforeLineageScan
    self.afterLineageScan = afterLineageScan
    self.onLineageDeepScan = onLineageDeepScan
  }

  public func scan(window: MonthWindow, fetchedAt: Date) throws -> LocalLogScanResult {
    var diagnostics: [LocalLogDiagnostic] = []
    let files = try LocalLogScanner.candidateFiles(
      sessionRoots: sessionRoots,
      window: window,
      diagnostics: &diagnostics
    )
    try beforeLineageScan()
    let lineage = try CodexLineageIndex.build(
      sessionRoots: sessionRoots,
      candidateFiles: files,
      onDeepScan: onLineageDeepScan
    )
    try afterLineageScan()
    let result = try LocalLogScanner(
      provider: .openAI,
      sessionRoots: sessionRoots,
      priceCatalog: priceCatalog,
      calendar: calendar,
      candidateLine: {
        $0.range(of: Self.turnContextMarker) != nil
          || $0.range(of: Self.tokenCountMarker) != nil
          || $0.range(of: Self.sessionMetadataMarker) != nil
      },
      parser: { object, context in
        Self.parse(object, context: &context, lineage: lineage[context.sourcePath])
      }
    ).scan(
      window: window,
      fetchedAt: fetchedAt,
      files: files,
      initialDiagnostics: diagnostics
    )
    let suppressedDiagnostics = files.compactMap { file -> LocalLogDiagnostic? in
      let path = file.url.resolvingSymlinksInPath().path
      guard lineage[path]?.suppressesUsage == true else { return nil }
      return .sourceUnavailable(file: file.url.lastPathComponent)
    }
    var combinedDiagnostics = result.diagnostics
    for diagnostic in suppressedDiagnostics where !combinedDiagnostics.contains(diagnostic) {
      combinedDiagnostics.append(diagnostic)
    }
    return LocalLogScanResult(
      records: result.records,
      diagnostics: combinedDiagnostics.sorted {
        String(describing: $0) < String(describing: $1)
      }
    )
  }

  private static let turnContextMarker = Data(#""turn_context""#.utf8)
  fileprivate static let tokenCountMarker = Data(#""token_count""#.utf8)
  fileprivate static let sessionMetadataMarker = Data(#""session_meta""#.utf8)

  private static func parse(
    _ object: [String: Any],
    context: inout LogParseContext,
    lineage: CodexLineage?
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
      let info = payload["info"] as? [String: Any]
    else {
      return nil
    }
    let totalObject = info["total_token_usage"] as? [String: Any]
    let lastObject = info["last_token_usage"] as? [String: Any]
    let total = totalObject.flatMap(CodexTokenCounters.init)
    let last = lastObject.flatMap(CodexTokenCounters.init)
    guard
      totalObject == nil || total != nil,
      lastObject == nil || last != nil,
      total != nil || last != nil
    else {
      return nil
    }
    if context.codexUsageState == nil {
      context.codexUsageState = CodexUsageState(lineage: lineage)
    }
    guard let delta = context.codexUsageState?.consume(total: total, last: last), !delta.isZero
    else {
      return nil
    }
    let eventID =
      string(in: object, keys: ["event_id", "id"])
      ?? string(in: payload, keys: ["event_id", "id"])
      ?? [
        "position:\(context.relativePath):\(context.lineNumber)",
        "timestamp:\(timestampValue)",
        "model:\(model)",
        "tokens:\(delta.input):\(delta.cached):\(delta.output)",
      ].joined(separator: "|")
    return LocalUsage(
      eventID: eventID,
      timestamp: timestamp,
      model: model,
      inputTokens: delta.input - delta.cached,
      cachedInputTokens: delta.cached,
      outputTokens: delta.output
    )
  }
}

struct CodexTokenCounters: Hashable, Sendable {
  let input: Int
  let cached: Int
  let output: Int

  init?(_ object: [String: Any]) {
    guard
      let input = integer(object["input_tokens"]),
      let output = integer(object["output_tokens"])
    else {
      return nil
    }
    let cached = integer(object["cached_input_tokens"] ?? object["cache_read_input_tokens"]) ?? 0
    guard input >= cached, cached >= 0, output >= 0 else {
      return nil
    }
    self.input = input
    self.cached = cached
    self.output = output
  }

  init(input: Int, cached: Int, output: Int) {
    self.input = input
    self.cached = min(cached, input)
    self.output = output
  }

  static let zero = Self(input: 0, cached: 0, output: 0)
  var isZero: Bool { input == 0 && cached == 0 && output == 0 }

  func positiveGrowth(from baseline: Self) -> Self {
    let input = max(0, input - baseline.input)
    return Self(
      input: input,
      cached: min(input, max(0, cached - baseline.cached)),
      output: max(0, output - baseline.output)
    )
  }

  func componentwiseMaximum(with other: Self) -> Self {
    Self(
      input: max(input, other.input),
      cached: max(cached, other.cached),
      output: max(output, other.output)
    )
  }

  func componentwiseMinimum(with other: Self) -> Self {
    Self(
      input: min(input, other.input),
      cached: min(cached, other.cached),
      output: min(output, other.output)
    )
  }

  func adding(_ other: Self) -> Self? {
    let (input, inputOverflow) = input.addingReportingOverflow(other.input)
    let (cached, cachedOverflow) = cached.addingReportingOverflow(other.cached)
    let (output, outputOverflow) = output.addingReportingOverflow(other.output)
    guard !inputOverflow, !cachedOverflow, !outputOverflow else { return nil }
    return Self(
      input: input,
      cached: cached,
      output: output
    )
  }

  func subtracting(_ other: Self) -> Self? {
    guard input >= other.input, cached >= other.cached, output >= other.output else {
      return nil
    }
    let input = input - other.input
    let cached = cached - other.cached
    guard input >= cached else { return nil }
    return Self(
      input: input,
      cached: cached,
      output: output - other.output
    )
  }
}

struct CodexLineage: Sendable {
  let inheritedBaseline: CodexTokenCounters?
  let isUnresolvedFork: Bool
  let fingerprints: [CodexFileFingerprint]

  var suppressesUsage: Bool {
    isUnresolvedFork || !fingerprints.allSatisfy { $0.isCurrent() }
  }
}

struct CodexUsageState {
  private var watermark: CodexTokenCounters?
  private var sawInterleavedTotals = false
  private var failed = false
  private let suppressUsage: Bool
  private let hasInheritedBaseline: Bool

  var currentWatermark: CodexTokenCounters? { watermark }
  var hasFailed: Bool { failed }

  init(lineage: CodexLineage?) {
    watermark = lineage?.inheritedBaseline
    suppressUsage = lineage?.suppressesUsage == true
    hasInheritedBaseline = lineage?.inheritedBaseline != nil
  }

  mutating func consume(
    total: CodexTokenCounters?,
    last: CodexTokenCounters?
  ) -> CodexTokenCounters? {
    guard !suppressUsage, !failed else { return nil }
    guard let total else {
      guard !hasInheritedBaseline, let last else { return nil }
      guard let nextWatermark = (watermark ?? .zero).adding(last) else {
        failed = true
        watermark = nil
        return nil
      }
      watermark = nextWatermark
      return last
    }
    let baseline = watermark ?? .zero
    if total.input < baseline.input || total.cached < baseline.cached
      || total.output < baseline.output
    {
      sawInterleavedTotals = true
    }
    var delta = total.positiveGrowth(from: baseline)
    if sawInterleavedTotals, let last {
      delta = delta.componentwiseMinimum(with: last)
    }
    watermark = baseline.componentwiseMaximum(with: total)
    return delta
  }
}

struct CodexFileFingerprint: Sendable {
  let path: String
  let size: Int
  let modificationDate: Date

  init?(file: URL) {
    guard
      let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
      let size = values.fileSize,
      let modificationDate = values.contentModificationDate
    else {
      return nil
    }
    path = file.resolvingSymlinksInPath().path
    self.size = size
    self.modificationDate = modificationDate
  }

  func isCurrent() -> Bool {
    guard let current = Self(file: URL(fileURLWithPath: path)) else { return false }
    return current.size == size && current.modificationDate == modificationDate
  }
}

private enum CodexLineageIndex {
  private struct Snapshot {
    let timestamp: Date
    let totals: CodexTokenCounters
    let localBaseline: CodexTokenCounters?
  }

  private struct SessionFile {
    let fingerprint: CodexFileFingerprint
    var sessionID: String?
    var parentSessionID: String?
    var hasEmbeddedAncestorMetadata = false
    var forkTimestamp: Date?
    var snapshots: [Snapshot] = []
    var usageState = CodexUsageState(lineage: nil)
  }

  private struct DiscoveredFile {
    let file: LocalLogFile
    let fingerprint: CodexFileFingerprint
    let sessionID: String?
  }

  private struct TimestampParser {
    private let standard = ISO8601DateFormatter()
    private let fractional: ISO8601DateFormatter = {
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      return formatter
    }()

    func parse(_ value: String) -> Date? {
      fractional.date(from: value) ?? standard.date(from: value)
    }
  }

  static func build(
    sessionRoots: [URL],
    candidateFiles: [LocalLogFile],
    onDeepScan: @Sendable (URL) -> Void
  ) throws -> [String: CodexLineage] {
    let timestampParser = TimestampParser()
    var discoveredByPath: [String: DiscoveredFile] = [:]
    for root in sessionRoots.map(\.standardizedFileURL) {
      guard
        let enumerator = FileManager.default.enumerator(
          at: root,
          includingPropertiesForKeys: [
            .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey,
          ],
          options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
      else {
        continue
      }
      while let file = enumerator.nextObject() as? URL {
        try Task.checkCancellation()
        guard
          let values = try? file.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey,
          ]),
          values.isSymbolicLink != true,
          values.isRegularFile == true,
          file.pathExtension == "jsonl"
        else {
          continue
        }
        guard let fingerprint = CodexFileFingerprint(file: file) else { continue }
        let localFile = LocalLogFile(root: root, url: file.standardizedFileURL)
        let path = file.resolvingSymlinksInPath().path
        discoveredByPath[path] = DiscoveredFile(
          file: localFile,
          fingerprint: fingerprint,
          sessionID: discoverSessionID(in: localFile)
        )
      }
    }

    var discoveredPathsBySessionID: [String: Set<String>] = [:]
    for path in discoveredByPath.keys.sorted() {
      guard let discovered = discoveredByPath[path], let sessionID = discovered.sessionID else {
        continue
      }
      discoveredPathsBySessionID[sessionID, default: []].insert(path)
    }

    var filesByPath: [String: SessionFile] = [:]
    for candidate in candidateFiles {
      let path = candidate.url.resolvingSymlinksInPath().path
      guard let discovered = discoveredByPath[path] else { continue }
      if let session = try deepScan(
        discovered,
        timestampParser: timestampParser,
        onDeepScan: onDeepScan
      ) {
        filesByPath[path] = session
        if let sessionID = session.sessionID {
          discoveredPathsBySessionID[sessionID, default: []].insert(path)
        }
      }
    }

    var pendingParentIDs = filesByPath.values.compactMap(\.parentSessionID)
    var visitedParentIDs: Set<String> = []
    while let parentID = pendingParentIDs.popLast() {
      try Task.checkCancellation()
      guard visitedParentIDs.insert(parentID).inserted,
        let paths = discoveredPathsBySessionID[parentID], paths.count == 1,
        let path = paths.first,
        let discovered = discoveredByPath[path]
      else {
        continue
      }
      if let existing = filesByPath[path] {
        if let ancestorID = existing.parentSessionID {
          pendingParentIDs.append(ancestorID)
        }
        continue
      }
      guard
        let session = try deepScan(
          discovered,
          timestampParser: timestampParser,
          onDeepScan: onDeepScan
        )
      else {
        continue
      }
      filesByPath[path] = session
      if let sessionID = session.sessionID {
        discoveredPathsBySessionID[sessionID, default: []].insert(path)
      }
      if let ancestorID = session.parentSessionID {
        pendingParentIDs.append(ancestorID)
      }
    }

    var sessionsByID: [String: SessionFile] = [:]
    for path in filesByPath.keys.sorted() {
      guard let file = filesByPath[path], let sessionID = file.sessionID else { continue }
      sessionsByID[sessionID] = sessionsByID[sessionID] ?? file
    }
    var lineageByPath = filesByPath.mapValues { file in
      guard !file.usageState.hasFailed else {
        return CodexLineage(
          inheritedBaseline: nil,
          isUnresolvedFork: true,
          fingerprints: [file.fingerprint]
        )
      }
      guard let parentID = file.parentSessionID else {
        return CodexLineage(
          inheritedBaseline: nil,
          isUnresolvedFork: false,
          fingerprints: [file.fingerprint]
        )
      }
      guard discoveredPathsBySessionID[parentID]?.count == 1,
        let parent = sessionsByID[parentID]
      else {
        return CodexLineage(
          inheritedBaseline: nil,
          isUnresolvedFork: true,
          fingerprints: [file.fingerprint]
        )
      }
      guard !parent.usageState.hasFailed else {
        return CodexLineage(
          inheritedBaseline: nil,
          isUnresolvedFork: true,
          fingerprints: [file.fingerprint, parent.fingerprint]
        )
      }
      let eligible = parent.snapshots.filter { snapshot in
        file.forkTimestamp.map { snapshot.timestamp <= $0 } ?? true
      }
      let baseline = eligible.reduce(nil as CodexTokenCounters?) { current, snapshot in
        current?.componentwiseMaximum(with: snapshot.totals) ?? snapshot.totals
      }
      let firstChildSnapshot = file.snapshots.first
      let matchesParentSnapshot =
        firstChildSnapshot.map { childSnapshot in
          eligible.contains { $0.totals == childSnapshot.totals }
        } ?? false
      let locallyConfirmsBaseline =
        if let baseline, let firstChildSnapshot {
          firstChildSnapshot.localBaseline == baseline
        } else {
          false
        }
      let hasCopiedPrefixEvidence =
        file.hasEmbeddedAncestorMetadata || matchesParentSnapshot || locallyConfirmsBaseline
      let hasIndependentCounterEvidence =
        firstChildSnapshot.map { !$0.totals.isZero && $0.localBaseline == .zero } ?? false
      if baseline == nil && !hasIndependentCounterEvidence {
        return CodexLineage(
          inheritedBaseline: nil,
          isUnresolvedFork: true,
          fingerprints: [file.fingerprint, parent.fingerprint]
        )
      }
      if !hasCopiedPrefixEvidence {
        return CodexLineage(
          inheritedBaseline: nil,
          isUnresolvedFork: false,
          fingerprints: [file.fingerprint, parent.fingerprint]
        )
      }
      return CodexLineage(
        inheritedBaseline: baseline,
        isUnresolvedFork: baseline == nil,
        fingerprints: [file.fingerprint, parent.fingerprint]
      )
    }
    for candidate in candidateFiles {
      let path = candidate.url.resolvingSymlinksInPath().path
      if lineageByPath[path] == nil {
        lineageByPath[path] = CodexLineage(
          inheritedBaseline: nil,
          isUnresolvedFork: true,
          fingerprints: []
        )
      }
    }
    return lineageByPath
  }

  private static func discoverSessionID(in file: LocalLogFile) -> String? {
    guard
      let prefix = try? LocalLogScanner.readFilePrefix(
        file: file.url,
        relativeTo: file.root,
        maximumBytes: 65_536
      )
    else {
      return nil
    }
    for line in prefix.split(separator: 0x0A) {
      let data = Data(line)
      guard
        data.range(of: CodexLogScanner.sessionMetadataMarker) != nil,
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        object["type"] as? String == "session_meta"
      else {
        continue
      }
      let payload = object["payload"] as? [String: Any] ?? [:]
      return identifier(in: payload, keys: ["session_id", "sessionId", "id"])
        ?? identifier(in: object, keys: ["session_id", "sessionId", "id"])
    }
    return nil
  }

  private static func deepScan(
    _ discovered: DiscoveredFile,
    timestampParser: TimestampParser,
    onDeepScan: @Sendable (URL) -> Void
  ) throws -> SessionFile? {
    var session = SessionFile(fingerprint: discovered.fingerprint)
    do {
      onDeepScan(discovered.file.url)
      try LocalLogScanner.scanFile(
        file: discovered.file.url,
        relativeTo: discovered.file.root
      ) { data, _ in
        guard
          data.range(of: CodexLogScanner.sessionMetadataMarker) != nil
            || data.range(of: CodexLogScanner.tokenCountMarker) != nil,
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
          return
        }
        if object["type"] as? String == "session_meta" {
          observeMetadata(object, in: &session, timestampParser: timestampParser)
        } else {
          observeSnapshot(object, in: &session, timestampParser: timestampParser)
        }
      }
      return session
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return nil
    }
  }

  private static func observeMetadata(
    _ object: [String: Any],
    in session: inout SessionFile,
    timestampParser: TimestampParser
  ) {
    let payload = object["payload"] as? [String: Any] ?? [:]
    let metadataID =
      identifier(in: payload, keys: ["session_id", "sessionId", "id"])
      ?? identifier(in: object, keys: ["session_id", "sessionId", "id"])
    if session.sessionID == nil {
      session.sessionID = metadataID
    }
    guard metadataID == nil || metadataID == session.sessionID else {
      session.hasEmbeddedAncestorMetadata = true
      return
    }
    session.parentSessionID =
      session.parentSessionID
      ?? parentSessionID(
        payload: payload,
        object: object
      )
    let timestamp = payload["timestamp"] as? String ?? object["timestamp"] as? String
    session.forkTimestamp = session.forkTimestamp ?? timestamp.flatMap(timestampParser.parse)
  }

  private static func observeSnapshot(
    _ object: [String: Any],
    in session: inout SessionFile,
    timestampParser: TimestampParser
  ) {
    guard
      object["type"] as? String == "event_msg",
      let timestamp = object["timestamp"] as? String,
      let date = timestampParser.parse(timestamp),
      let payload = object["payload"] as? [String: Any],
      payload["type"] as? String == "token_count",
      let info = payload["info"] as? [String: Any]
    else {
      return
    }
    let totalObject = info["total_token_usage"] as? [String: Any]
    let lastObject = info["last_token_usage"] as? [String: Any]
    let total = totalObject.flatMap(CodexTokenCounters.init)
    let last = lastObject.flatMap(CodexTokenCounters.init)
    guard
      totalObject == nil || total != nil,
      lastObject == nil || last != nil,
      total != nil || last != nil
    else {
      return
    }
    let localBaseline: CodexTokenCounters? =
      if let total, let last {
        total.subtracting(last)
      } else {
        nil
      }
    _ = session.usageState.consume(total: total, last: last)
    guard !session.usageState.hasFailed,
      let totals = session.usageState.currentWatermark
    else {
      return
    }
    session.snapshots.append(
      Snapshot(timestamp: date, totals: totals, localBaseline: localBaseline)
    )
  }

  private static func parentSessionID(
    payload: [String: Any],
    object: [String: Any]
  ) -> String? {
    let keys = ["forked_from_id", "forkedFromId", "parent_session_id", "parentSessionId"]
    if let direct = identifier(
      in: payload,
      keys: keys
    )
      ?? identifier(
        in: object,
        keys: keys
      )
    {
      return direct
    }
    guard
      let source = payload["source"] as? [String: Any],
      let subagent = source["subagent"] as? [String: Any],
      let spawn = subagent["thread_spawn"] as? [String: Any]
    else {
      return nil
    }
    return identifier(in: spawn, keys: ["parent_thread_id", "parentThreadId"])
  }

  private static func identifier(in object: [String: Any], keys: [String]) -> String? {
    guard
      let value = string(in: object, keys: keys)?.trimmingCharacters(in: .whitespacesAndNewlines)
    else {
      return nil
    }
    return value.isEmpty ? nil : value
  }
}
