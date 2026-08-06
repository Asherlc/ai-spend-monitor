import AISpendCore
import Foundation

public struct CodexLogScanner: Sendable {
  private let sessionRoots: [URL]
  private let priceCatalog: PriceCatalog
  private let calendar: Calendar
  private let beforeLineageScan: @Sendable () throws -> Void
  private let afterLineageScan: @Sendable () throws -> Void
  private let onFullFileScan: @Sendable (URL) -> Void
  private let onDeepScanLine: @Sendable (Data, Int) -> Void
  private let onRetentionMetrics: @Sendable (CodexRetentionMetrics) -> Void

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
    onFullFileScan: @escaping @Sendable (URL) -> Void = { _ in },
    onDeepScanLine: @escaping @Sendable (Data, Int) -> Void = { _, _ in },
    onRetentionMetrics: @escaping @Sendable (CodexRetentionMetrics) -> Void = { _ in }
  ) {
    self.sessionRoots = sessionRoots
    self.priceCatalog = priceCatalog
    self.calendar = calendar
    self.beforeLineageScan = beforeLineageScan
    self.afterLineageScan = afterLineageScan
    self.onFullFileScan = onFullFileScan
    self.onDeepScanLine = onDeepScanLine
    self.onRetentionMetrics = onRetentionMetrics
  }

  public func scan(window: MonthWindow, fetchedAt: Date) throws -> LocalLogScanResult {
    var diagnostics: [LocalLogDiagnostic] = []
    let files = try LocalLogScanner.candidateFiles(
      sessionRoots: sessionRoots,
      window: window,
      diagnostics: &diagnostics
    )
    try beforeLineageScan()
    let build = try CodexLineageIndex.build(
      sessionRoots: sessionRoots,
      candidateFiles: files,
      onDeepScan: onFullFileScan,
      onDeepScanLine: onDeepScanLine
    )
    onRetentionMetrics(build.retentionMetrics)
    try afterLineageScan()
    try Task.checkCancellation()
    diagnostics.append(contentsOf: build.diagnostics)
    var usages: [LocalUsage] = []
    for candidate in build.candidates {
      try Task.checkCancellation()
      guard
        let lineage = build.lineage[candidate.sourcePath],
        !lineage.suppressesUsage
      else {
        Self.appendSourceUnavailable(candidate.fileName, to: &diagnostics)
        continue
      }
      var usageState = CodexUsageState(lineage: lineage)
      for event in candidate.events {
        try Task.checkCancellation()
        if let usage = event.replay(
          relativePath: candidate.relativePath,
          usageState: &usageState
        ) {
          usages.append(usage)
        }
      }
    }
    let retainedPaths = Set(build.candidates.map(\.sourcePath))
    for file in files {
      try Task.checkCancellation()
      let path = file.url.resolvingSymlinksInPath().path
      if !retainedPaths.contains(path), build.lineage[path]?.suppressesUsage == true {
        Self.appendSourceUnavailable(file.url.lastPathComponent, to: &diagnostics)
      }
    }
    return try LocalLogScanner.scan(
      provider: .openAI,
      priceCatalog: priceCatalog,
      calendar: calendar,
      window: window,
      fetchedAt: fetchedAt,
      usages: usages,
      initialDiagnostics: diagnostics
    )
  }

  fileprivate static let turnContextMarker = Data(#""turn_context""#.utf8)
  fileprivate static let tokenCountMarker = Data(#""token_count""#.utf8)
  fileprivate static let sessionMetadataMarker = Data(#""session_meta""#.utf8)
  fileprivate static let interAgentMarker = Data(#""inter_agent_communication_metadata""#.utf8)

  private static func appendSourceUnavailable(
    _ fileName: String,
    to diagnostics: inout [LocalLogDiagnostic]
  ) {
    let diagnostic = LocalLogDiagnostic.sourceUnavailable(file: fileName)
    if !diagnostics.contains(diagnostic) {
      diagnostics.append(diagnostic)
    }
  }
}

struct CodexRetentionMetrics: Equatable, Sendable {
  let scannedFileCount: Int
}

private struct CodexLineageSnapshot: Sendable {
  let timestamp: Date
  let totals: CodexTokenCounters
  let localBaseline: CodexTokenCounters?
}

private struct CodexRetainedUsageEvent: Sendable {
  let timestampValue: String
  let timestamp: Date
  let model: String?
  let total: CodexTokenCounters?
  let last: CodexTokenCounters?
  let explicitEventID: String?
  let lineNumber: Int
  let lineageTotals: CodexTokenCounters?
  let localBaseline: CodexTokenCounters?

  var lineageSnapshot: CodexLineageSnapshot? {
    guard let lineageTotals else { return nil }
    return CodexLineageSnapshot(
      timestamp: timestamp,
      totals: lineageTotals,
      localBaseline: localBaseline
    )
  }

  func replay(
    relativePath: String,
    usageState: inout CodexUsageState
  ) -> LocalUsage? {
    guard
      let model,
      let delta = usageState.consume(total: total, last: last),
      !delta.isZero
    else {
      return nil
    }
    let eventID =
      explicitEventID
      ?? [
        "position:\(relativePath):\(lineNumber)",
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

private struct CodexRetainedCandidate: Sendable {
  let fileName: String
  let relativePath: String
  let sourcePath: String
  let events: [CodexRetainedUsageEvent]
}

private struct CodexLineageBuild: Sendable {
  let lineage: [String: CodexLineage]
  let candidates: [CodexRetainedCandidate]
  let diagnostics: [LocalLogDiagnostic]
  let retentionMetrics: CodexRetentionMetrics
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

  func isAtLeast(_ other: Self) -> Bool {
    input >= other.input && cached >= other.cached && output >= other.output
  }

  func isAtMost(_ other: Self) -> Bool {
    input <= other.input && cached <= other.cached && output <= other.output
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

  var suppressesUsage: Bool {
    isUnresolvedFork
  }
}

struct CodexUsageState {
  private static let seenTotalsLimit = 64

  private var countedTotals: CodexTokenCounters?
  private var rawTotalsBaseline: CodexTokenCounters?
  private var watermark: CodexTokenCounters?
  private var lineageRawWatermark: CodexTokenCounters?
  private var seenRawTotals: [CodexTokenCounters] = []
  private var sawInterleavedTotals = false
  private var sawDivergentTotals = false
  private var failed = false
  private let suppressUsage: Bool
  private let inheritedBaseline: CodexTokenCounters?

  var currentWatermark: CodexTokenCounters? { lineageRawWatermark }
  var hasFailed: Bool { failed }

  init(lineage: CodexLineage?) {
    inheritedBaseline = lineage?.inheritedBaseline
    suppressUsage = lineage?.suppressesUsage == true
  }

  mutating func consume(
    total: CodexTokenCounters?,
    last: CodexTokenCounters?
  ) -> CodexTokenCounters? {
    guard !suppressUsage, !failed else { return nil }
    if let total {
      lineageRawWatermark = lineageRawWatermark?.componentwiseMaximum(with: total) ?? total
    }
    let adjustedTotal = total.map { value in
      inheritedBaseline.map { value.positiveGrowth(from: $0) } ?? value
    }
    if let adjustedTotal {
      if seenRawTotals.contains(adjustedTotal) {
        return nil
      }
      if let watermark,
        adjustedTotal.input < watermark.input || adjustedTotal.cached < watermark.cached
          || adjustedTotal.output < watermark.output
      {
        sawInterleavedTotals = true
      }
    }
    let watermarkBaseline = watermark ?? rawTotalsBaseline
    defer {
      if let adjustedTotal {
        watermark = watermark?.componentwiseMaximum(with: adjustedTotal) ?? adjustedTotal
        if !seenRawTotals.contains(adjustedTotal) {
          seenRawTotals.append(adjustedTotal)
          if seenRawTotals.count > Self.seenTotalsLimit {
            seenRawTotals.removeFirst(seenRawTotals.count - Self.seenTotalsLimit)
          }
        }
      }
    }

    let base = countedTotals ?? .zero
    if let adjustedTotal, inheritedBaseline != nil {
      var delta = totalsDerivedDelta(
        current: adjustedTotal,
        watermarkBaseline: watermarkBaseline
      )
      if sawInterleavedTotals, let last {
        delta = delta.componentwiseMinimum(with: last)
      }
      return commit(delta: delta, current: adjustedTotal, base: base)
    }

    if let last {
      var delta = last
      if let adjustedTotal {
        if sawInterleavedTotals {
          delta = containedDelta(
            current: adjustedTotal,
            watermarkBaseline: watermarkBaseline
          ).componentwiseMinimum(with: last)
        } else {
          let totalDelta = adjustedTotal.positiveGrowth(from: watermarkBaseline ?? .zero)
          if !sawDivergentTotals,
            let watermarkBaseline,
            adjustedTotal.isAtLeast(watermarkBaseline),
            totalDelta.isAtMost(last)
          {
            delta = totalDelta
          }
        }
        return commit(delta: delta, current: adjustedTotal, base: base)
      }
      guard let counted = base.adding(delta) else {
        fail()
        return nil
      }
      countedTotals = counted
      rawTotalsBaseline = counted
      watermark = watermark?.componentwiseMaximum(with: counted) ?? counted
      lineageRawWatermark = lineageRawWatermark?.componentwiseMaximum(with: counted) ?? counted
      return delta
    }

    if let adjustedTotal {
      let delta = totalsDerivedDelta(
        current: adjustedTotal,
        watermarkBaseline: watermarkBaseline
      )
      return commit(delta: delta, current: adjustedTotal, base: base)
    }
    return nil
  }

  private mutating func commit(
    delta: CodexTokenCounters,
    current: CodexTokenCounters,
    base: CodexTokenCounters
  ) -> CodexTokenCounters? {
    guard let counted = base.adding(delta) else {
      fail()
      return nil
    }
    countedTotals = counted
    rawTotalsBaseline = current
    if counted != current {
      sawDivergentTotals = true
    }
    return delta
  }

  private func totalsDerivedDelta(
    current: CodexTokenCounters,
    watermarkBaseline: CodexTokenCounters?
  ) -> CodexTokenCounters {
    if sawInterleavedTotals {
      return containedDelta(current: current, watermarkBaseline: watermarkBaseline)
    }
    if sawDivergentTotals {
      let raw = watermarkBaseline ?? .zero
      let counted = countedTotals ?? .zero
      return Self.deltaFromDivergent(raw: raw, counted: counted, current: current)
    }
    return current.positiveGrowth(from: watermarkBaseline ?? .zero)
  }

  private func containedDelta(
    current: CodexTokenCounters,
    watermarkBaseline: CodexTokenCounters?
  ) -> CodexTokenCounters {
    let water = watermarkBaseline ?? .zero
    let counted = countedTotals ?? .zero
    return Self.deltaFromContained(water: water, counted: counted, current: current)
  }

  private static func deltaFromDivergent(
    raw: CodexTokenCounters,
    counted: CodexTokenCounters,
    current: CodexTokenCounters
  ) -> CodexTokenCounters {
    func component(_ raw: Int, _ counted: Int, _ current: Int) -> Int {
      current >= raw ? max(0, current - raw) : max(0, current - counted)
    }
    return CodexTokenCounters(
      input: component(raw.input, counted.input, current.input),
      cached: component(raw.cached, counted.cached, current.cached),
      output: component(raw.output, counted.output, current.output)
    )
  }

  private static func deltaFromContained(
    water: CodexTokenCounters,
    counted: CodexTokenCounters,
    current: CodexTokenCounters
  ) -> CodexTokenCounters {
    func component(_ water: Int, _ counted: Int, _ current: Int) -> Int {
      current >= water
        ? max(0, current - max(water, counted))
        : max(0, current - counted)
    }
    return CodexTokenCounters(
      input: component(water.input, counted.input, current.input),
      cached: component(water.cached, counted.cached, current.cached),
      output: component(water.output, counted.output, current.output)
    )
  }

  private mutating func fail() {
    failed = true
    countedTotals = nil
    watermark = nil
    lineageRawWatermark = nil
  }
}

private enum CodexLineageIndex {
  private struct SessionFile {
    var sessionID: String?
    var parentSessionID: String?
    var hasObservedMetadata = false
    var hasEmbeddedAncestorMetadata = false
    var isSubagentThread = false
    var forkTimestamp: Date?
    var historicalSnapshots: [CodexLineageSnapshot] = []
    var usageState = CodexUsageState(lineage: nil)
    var sourceUnavailable = false
  }

  private struct DiscoveredFile {
    let file: LocalLogFile
    let sessionID: String?
  }

  private struct SessionReference {
    let path: String
    let file: SessionFile
  }

  private struct ParsedTokenEvent {
    let timestampValue: String
    let timestamp: Date
    let model: String?
    let total: CodexTokenCounters?
    let last: CodexTokenCounters?
    let explicitEventID: String?
    let localBaseline: CodexTokenCounters?
  }

  private struct ParsedTokenLine {
    let event: ParsedTokenEvent
    let lineNumber: Int
  }

  private struct LocalBoundaryCandidate {
    let startLineNumber: Int
    let baseline: CodexTokenCounters
    var isLocallyConfirmed = false
  }

  private struct ParentSnapshotEvidence {
    var baseline: CodexTokenCounters?
    var matchesFirstChild = false
  }

  private struct DeepScanResult {
    let session: SessionFile
    let retainedEvents: [CodexRetainedUsageEvent]
    let diagnostics: [LocalLogDiagnostic]
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
    onDeepScan: @Sendable (URL) -> Void,
    onDeepScanLine: @Sendable (Data, Int) -> Void
  ) throws -> CodexLineageBuild {
    let timestampParser = TimestampParser()
    let canonicalCandidates = canonicalFiles(candidateFiles)
    var discoveredByPath: [String: DiscoveredFile] = [:]
    var seenRootPaths: Set<String> = []
    let canonicalRoots = sessionRoots.map(\.standardizedFileURL).sorted { $0.path < $1.path }
      .filter { seenRootPaths.insert($0.path).inserted }
    for root in canonicalRoots {
      guard
        let enumerator = FileManager.default.enumerator(
          at: root,
          includingPropertiesForKeys: [
            .isRegularFileKey, .isSymbolicLinkKey,
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
        let localFile = LocalLogFile(root: root, url: file.standardizedFileURL)
        let path = file.resolvingSymlinksInPath().path
        if discoveredByPath[path] == nil {
          discoveredByPath[path] = DiscoveredFile(
            file: localFile,
            sessionID: discoverSessionID(in: localFile)
          )
        }
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
    var retainedCandidatesByPath: [String: CodexRetainedCandidate] = [:]
    var diagnostics: [LocalLogDiagnostic] = []
    for candidate in canonicalCandidates {
      try Task.checkCancellation()
      let path = candidate.url.resolvingSymlinksInPath().path
      guard let discovered = discoveredByPath[path] else { continue }
      if let result = try deepScan(
        discovered,
        timestampParser: timestampParser,
        retainCandidateEvents: true,
        onDeepScan: onDeepScan,
        onDeepScanLine: onDeepScanLine
      ) {
        filesByPath[path] = result.session
        retainedCandidatesByPath[path] = CodexRetainedCandidate(
          fileName: candidate.url.lastPathComponent,
          relativePath: relativePath(candidate.url, to: candidate.root),
          sourcePath: path,
          events: result.retainedEvents
        )
        diagnostics.append(contentsOf: result.diagnostics)
        if let sessionID = result.session.sessionID {
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
        let result = try deepScan(
          discovered,
          timestampParser: timestampParser,
          retainCandidateEvents: false,
          onDeepScan: onDeepScan,
          onDeepScanLine: onDeepScanLine
        )
      else {
        continue
      }
      let session = result.session
      filesByPath[path] = session
      if let sessionID = session.sessionID {
        discoveredPathsBySessionID[sessionID, default: []].insert(path)
      }
      if let ancestorID = session.parentSessionID {
        pendingParentIDs.append(ancestorID)
      }
    }

    var sessionsByID: [String: SessionReference] = [:]
    for path in filesByPath.keys.sorted() {
      guard let file = filesByPath[path], let sessionID = file.sessionID else { continue }
      sessionsByID[sessionID] = sessionsByID[sessionID] ?? SessionReference(path: path, file: file)
    }
    var parentPathByPath: [String: String] = [:]
    for path in filesByPath.keys.sorted() {
      try Task.checkCancellation()
      guard let file = filesByPath[path] else { continue }
      if let parentID = file.parentSessionID,
        let paths = discoveredPathsBySessionID[parentID],
        paths.count == 1,
        let parent = sessionsByID[parentID],
        paths.contains(parent.path)
      {
        parentPathByPath[path] = parent.path
      }
    }

    var lineageByPath: [String: CodexLineage] = [:]
    for candidate in canonicalCandidates {
      try Task.checkCancellation()
      let path = candidate.url.resolvingSymlinksInPath().path
      guard let file = filesByPath[path] else { continue }
      guard !file.sourceUnavailable, !file.usageState.hasFailed else {
        lineageByPath[path] = CodexLineage(
          inheritedBaseline: nil,
          isUnresolvedFork: true
        )
        continue
      }
      guard let parentID = file.parentSessionID else {
        lineageByPath[path] = CodexLineage(
          inheritedBaseline: nil,
          isUnresolvedFork: false
        )
        continue
      }
      guard discoveredPathsBySessionID[parentID]?.count == 1,
        let parentReference = sessionsByID[parentID],
        parentPathByPath[path] == parentReference.path
      else {
        lineageByPath[path] = CodexLineage(
          inheritedBaseline: nil,
          isUnresolvedFork: true
        )
        continue
      }
      let parent = parentReference.file
      guard !parent.sourceUnavailable, !parent.usageState.hasFailed else {
        lineageByPath[path] = CodexLineage(
          inheritedBaseline: nil,
          isUnresolvedFork: true
        )
        continue
      }
      let firstChildSnapshot = try firstSnapshot(
        for: SessionReference(path: path, file: file),
        retainedCandidatesByPath: retainedCandidatesByPath
      )
      let parentEvidence = try parentSnapshotEvidence(
        for: parentReference,
        through: file.forkTimestamp,
        firstChildTotals: firstChildSnapshot?.totals,
        retainedCandidatesByPath: retainedCandidatesByPath
      )
      let baseline = parentEvidence.baseline
      let locallyConfirmsBaseline =
        if let baseline, let firstChildSnapshot {
          firstChildSnapshot.localBaseline == baseline
        } else {
          false
        }
      let hasCopiedPrefixEvidence =
        file.hasEmbeddedAncestorMetadata || parentEvidence.matchesFirstChild
        || locallyConfirmsBaseline
      let hasIndependentCounterEvidence =
        firstChildSnapshot.map { !$0.totals.isZero && $0.localBaseline == .zero } ?? false
      if baseline == nil && !hasIndependentCounterEvidence {
        lineageByPath[path] = CodexLineage(
          inheritedBaseline: nil,
          isUnresolvedFork: true
        )
        continue
      }
      if !hasCopiedPrefixEvidence {
        lineageByPath[path] = CodexLineage(
          inheritedBaseline: nil,
          isUnresolvedFork: false
        )
        continue
      }
      lineageByPath[path] = CodexLineage(
        inheritedBaseline: baseline,
        isUnresolvedFork: baseline == nil
      )
    }
    for candidate in canonicalCandidates {
      let path = candidate.url.resolvingSymlinksInPath().path
      if lineageByPath[path] == nil {
        lineageByPath[path] = CodexLineage(
          inheritedBaseline: nil,
          isUnresolvedFork: true
        )
      }
    }
    let candidates = canonicalCandidates.compactMap { candidate in
      retainedCandidatesByPath[candidate.url.resolvingSymlinksInPath().path]
    }
    return CodexLineageBuild(
      lineage: lineageByPath,
      candidates: candidates,
      diagnostics: diagnostics,
      retentionMetrics: CodexRetentionMetrics(
        scannedFileCount: filesByPath.count
      )
    )
  }

  private static func canonicalFiles(_ files: [LocalLogFile]) -> [LocalLogFile] {
    var seenPaths: Set<String> = []
    return files.sorted { lhs, rhs in
      if lhs.root.path != rhs.root.path {
        return lhs.root.path < rhs.root.path
      }
      return lhs.url.path < rhs.url.path
    }.filter { file in
      seenPaths.insert(file.url.resolvingSymlinksInPath().path).inserted
    }
  }

  private static func firstSnapshot(
    for reference: SessionReference,
    retainedCandidatesByPath: [String: CodexRetainedCandidate]
  ) throws -> CodexLineageSnapshot? {
    if let candidate = retainedCandidatesByPath[reference.path] {
      for event in candidate.events {
        try Task.checkCancellation()
        if let snapshot = event.lineageSnapshot {
          return snapshot
        }
      }
      return nil
    }
    try Task.checkCancellation()
    return reference.file.historicalSnapshots.first
  }

  private static func parentSnapshotEvidence(
    for reference: SessionReference,
    through forkTimestamp: Date?,
    firstChildTotals: CodexTokenCounters?,
    retainedCandidatesByPath: [String: CodexRetainedCandidate]
  ) throws -> ParentSnapshotEvidence {
    var evidence = ParentSnapshotEvidence()
    try forEachSnapshot(
      in: reference,
      retainedCandidatesByPath: retainedCandidatesByPath
    ) { snapshot in
      guard forkTimestamp.map({ snapshot.timestamp <= $0 }) ?? true else { return }
      evidence.baseline =
        evidence.baseline?.componentwiseMaximum(with: snapshot.totals) ?? snapshot.totals
      if snapshot.totals == firstChildTotals {
        evidence.matchesFirstChild = true
      }
    }
    return evidence
  }

  private static func forEachSnapshot(
    in reference: SessionReference,
    retainedCandidatesByPath: [String: CodexRetainedCandidate],
    _ body: (CodexLineageSnapshot) -> Void
  ) throws {
    if let candidate = retainedCandidatesByPath[reference.path] {
      for event in candidate.events {
        try Task.checkCancellation()
        if let snapshot = event.lineageSnapshot {
          body(snapshot)
        }
      }
      return
    }
    for snapshot in reference.file.historicalSnapshots {
      try Task.checkCancellation()
      body(snapshot)
    }
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
      return sessionIdentifier(payload: payload, object: object)
    }
    return nil
  }

  private static func deepScan(
    _ discovered: DiscoveredFile,
    timestampParser: TimestampParser,
    retainCandidateEvents: Bool,
    onDeepScan: @Sendable (URL) -> Void,
    onDeepScanLine: @Sendable (Data, Int) -> Void
  ) throws -> DeepScanResult? {
    var session = SessionFile()
    var currentModel: String?
    var retainedEvents: [CodexRetainedUsageEvent] = []
    var parsedTokenLines: [ParsedTokenLine] = []
    var lastRawTotals: CodexTokenCounters?
    var pendingBoundary: (lineNumber: Int, baseline: CodexTokenCounters)?
    var boundaryCandidate: LocalBoundaryCandidate?
    var diagnostics: [LocalLogDiagnostic] = []
    do {
      onDeepScan(discovered.file.url)
      try LocalLogScanner.scanFile(
        file: discovered.file.url,
        relativeTo: discovered.file.root,
        markerBytes: [
          CodexLogScanner.turnContextMarker,
          CodexLogScanner.tokenCountMarker,
          CodexLogScanner.sessionMetadataMarker,
          CodexLogScanner.interAgentMarker,
        ]
      ) { data, lineNumber in
        onDeepScanLine(data, lineNumber)
        guard
          let object = try? JSONSerialization.jsonObject(with: data),
          let dictionary = object as? [String: Any]
        else {
          if retainCandidateEvents, !data.isEmpty {
            diagnostics.append(
              .malformedLine(file: discovered.file.url.lastPathComponent, line: lineNumber)
            )
          }
          return
        }
        if dictionary["type"] as? String == "session_meta" {
          let hadEmbeddedAncestor = session.hasEmbeddedAncestorMetadata
          observeMetadata(dictionary, in: &session, timestampParser: timestampParser)
          if !hadEmbeddedAncestor, session.hasEmbeddedAncestorMetadata {
            pendingBoundary = nil
            boundaryCandidate = nil
          }
          return
        }
        if dictionary["type"] as? String == "turn_context" {
          let payload = dictionary["payload"] as? [String: Any]
          if let model = payload?["model"] as? String {
            currentModel = model
          }
          pendingBoundary =
            if session.isSubagentThread, let lastRawTotals {
              (lineNumber, lastRawTotals)
            } else {
              nil
            }
          return
        }
        if dictionary["type"] as? String == "inter_agent_communication_metadata" {
          let payload = dictionary["payload"] as? [String: Any]
          if boundaryCandidate == nil,
            payload?["trigger_turn"] as? Bool == true,
            let pendingBoundary,
            lineNumber == pendingBoundary.lineNumber + 1,
            !pendingBoundary.baseline.isZero
          {
            boundaryCandidate = LocalBoundaryCandidate(
              startLineNumber: pendingBoundary.lineNumber,
              baseline: pendingBoundary.baseline
            )
          }
          pendingBoundary = nil
          return
        }
        guard
          let event = parsedTokenEvent(
            dictionary,
            currentModel: currentModel,
            timestampParser: timestampParser
          )
        else {
          return
        }
        if var candidate = boundaryCandidate,
          !candidate.isLocallyConfirmed,
          event.localBaseline == candidate.baseline
        {
          candidate.isLocallyConfirmed = true
          boundaryCandidate = candidate
        }
        parsedTokenLines.append(ParsedTokenLine(event: event, lineNumber: lineNumber))
        lastRawTotals = event.total
        pendingBoundary = nil
      }

      let acceptedBoundary = boundaryCandidate.flatMap { candidate in
        candidate.isLocallyConfirmed || session.hasEmbeddedAncestorMetadata ? candidate : nil
      }
      session.usageState = CodexUsageState(
        lineage: acceptedBoundary.map {
          CodexLineage(inheritedBaseline: $0.baseline, isUnresolvedFork: false)
        }
      )
      for parsedLine in parsedTokenLines
      where
        acceptedBoundary.map({ parsedLine.lineNumber >= $0.startLineNumber }) ?? true
      {
        let event = parsedLine.event
        let snapshot = lineageSnapshot(for: event, in: &session)
        if retainCandidateEvents {
          retainedEvents.append(
            CodexRetainedUsageEvent(
              timestampValue: event.timestampValue,
              timestamp: event.timestamp,
              model: event.model,
              total: event.total,
              last: event.last,
              explicitEventID: event.explicitEventID,
              lineNumber: parsedLine.lineNumber,
              lineageTotals: snapshot?.totals,
              localBaseline: event.localBaseline
            )
          )
        } else if let snapshot {
          session.historicalSnapshots.append(snapshot)
        }
      }
      return DeepScanResult(
        session: session,
        retainedEvents: retainedEvents,
        diagnostics: diagnostics
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      session.sourceUnavailable = true
      return DeepScanResult(
        session: session,
        retainedEvents: retainedEvents,
        diagnostics: diagnostics
      )
    }
  }

  private static func parsedTokenEvent(
    _ object: [String: Any],
    currentModel: String?,
    timestampParser: TimestampParser
  ) -> ParsedTokenEvent? {
    guard
      object["type"] as? String == "event_msg",
      let timestampValue = object["timestamp"] as? String,
      let timestamp = timestampParser.parse(timestampValue),
      let payload = object["payload"] as? [String: Any],
      payload["type"] as? String == "token_count",
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
    let localBaseline: CodexTokenCounters? =
      if let total, let last {
        total.subtracting(last)
      } else {
        nil
      }
    return ParsedTokenEvent(
      timestampValue: timestampValue,
      timestamp: timestamp,
      model: payload["model"] as? String ?? currentModel,
      total: total,
      last: last,
      explicitEventID: string(in: object, keys: ["event_id", "id"])
        ?? string(in: payload, keys: ["event_id", "id"]),
      localBaseline: localBaseline
    )
  }

  private static func relativePath(_ file: URL, to root: URL) -> String {
    let rootComponents = root.standardizedFileURL.pathComponents
    return file.standardizedFileURL.pathComponents
      .dropFirst(rootComponents.count)
      .joined(separator: "/")
  }

  private static func observeMetadata(
    _ object: [String: Any],
    in session: inout SessionFile,
    timestampParser: TimestampParser
  ) {
    let payload = object["payload"] as? [String: Any] ?? [:]
    session.isSubagentThread = session.isSubagentThread || isSubagentSource(payload["source"])
    let metadataID = sessionIdentifier(payload: payload, object: object)
    if !session.hasObservedMetadata {
      session.hasObservedMetadata = true
      session.sessionID = metadataID
    } else if metadataID != session.sessionID {
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

  private static func isSubagentSource(_ source: Any?) -> Bool {
    if let source = source as? String {
      return source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "subagent"
    }
    guard let source = source as? [String: Any] else { return false }
    return source["subagent"] is String || source["subagent"] is [String: Any]
  }

  private static func lineageSnapshot(
    for event: ParsedTokenEvent,
    in session: inout SessionFile
  ) -> CodexLineageSnapshot? {
    _ = session.usageState.consume(total: event.total, last: event.last)
    guard !session.usageState.hasFailed,
      let totals = session.usageState.currentWatermark
    else {
      return nil
    }
    return CodexLineageSnapshot(
      timestamp: event.timestamp,
      totals: totals,
      localBaseline: event.localBaseline
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

  private static func sessionIdentifier(
    payload: [String: Any],
    object: [String: Any]
  ) -> String? {
    identifier(in: payload, keys: ["id"])
      ?? identifier(in: object, keys: ["id"])
      ?? identifier(in: payload, keys: ["session_id"])
      ?? identifier(in: payload, keys: ["sessionId"])
      ?? identifier(in: object, keys: ["session_id"])
      ?? identifier(in: object, keys: ["sessionId"])
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
