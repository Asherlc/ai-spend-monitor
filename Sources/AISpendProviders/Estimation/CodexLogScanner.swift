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
    let currentCandidatePaths = try build.currentCandidatePaths()
    diagnostics.append(contentsOf: build.diagnostics)
    var usages: [LocalUsage] = []
    for candidate in build.candidates {
      try Task.checkCancellation()
      guard
        let lineage = build.lineage[candidate.sourcePath],
        !lineage.suppressesUsage,
        currentCandidatePaths.contains(candidate.sourcePath)
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
  let retainedFingerprintCount: Int
  let materializedCandidateSnapshotCount: Int
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
  let fingerprintsByPath: [String: CodexFileFingerprint]
  let parentPathByPath: [String: String]
  let retentionMetrics: CodexRetentionMetrics

  func currentCandidatePaths() throws -> Set<String> {
    var fingerprintIsCurrent: [String: Bool] = [:]
    for path in fingerprintsByPath.keys.sorted() {
      try Task.checkCancellation()
      guard let fingerprint = fingerprintsByPath[path] else { continue }
      fingerprintIsCurrent[path] = fingerprint.isCurrent()
    }

    var validityByPath: [String: Bool] = [:]
    var currentCandidates: Set<String> = []
    for candidate in candidates {
      try Task.checkCancellation()
      var trail: [String] = []
      var visitedPaths: Set<String> = []
      var currentPath: String? = candidate.sourcePath
      var isValid: Bool?
      while let path = currentPath {
        try Task.checkCancellation()
        if let memoized = validityByPath[path] {
          isValid = memoized
          break
        }
        guard fingerprintIsCurrent[path] == true, visitedPaths.insert(path).inserted else {
          isValid = false
          break
        }
        trail.append(path)
        guard let parentPath = parentPathByPath[path] else {
          isValid = true
          break
        }
        currentPath = parentPath
      }
      let resolvedValidity = isValid == true
      for path in trail {
        validityByPath[path] = resolvedValidity
      }
      if resolvedValidity {
        currentCandidates.insert(candidate.sourcePath)
      }
    }
    return currentCandidates
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

  var suppressesUsage: Bool {
    isUnresolvedFork
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
  private struct SessionFile {
    let fingerprint: CodexFileFingerprint
    var sessionID: String?
    var parentSessionID: String?
    var hasEmbeddedAncestorMetadata = false
    var forkTimestamp: Date?
    var historicalSnapshots: [CodexLineageSnapshot] = []
    var usageState = CodexUsageState(lineage: nil)
    var sourceUnavailable = false
  }

  private struct DiscoveredFile {
    let file: LocalLogFile
    let fingerprint: CodexFileFingerprint
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
        if discoveredByPath[path] == nil {
          discoveredByPath[path] = DiscoveredFile(
            file: localFile,
            fingerprint: fingerprint,
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
      fingerprintsByPath: filesByPath.mapValues(\.fingerprint),
      parentPathByPath: parentPathByPath,
      retentionMetrics: CodexRetentionMetrics(
        scannedFileCount: filesByPath.count,
        retainedFingerprintCount: filesByPath.count,
        materializedCandidateSnapshotCount: 0
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
    var session = SessionFile(fingerprint: discovered.fingerprint)
    var currentModel: String?
    var retainedEvents: [CodexRetainedUsageEvent] = []
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
        ]
      ) { data, lineNumber in
        onDeepScanLine(data, lineNumber)
        guard
          let object = try? JSONSerialization.jsonObject(with: data),
          let dictionary = object as? [String: Any]
        else {
          if retainCandidateEvents {
            diagnostics.append(
              .malformedLine(file: discovered.file.url.lastPathComponent, line: lineNumber)
            )
          }
          return
        }
        if dictionary["type"] as? String == "session_meta" {
          observeMetadata(dictionary, in: &session, timestampParser: timestampParser)
          return
        }
        if dictionary["type"] as? String == "turn_context",
          let payload = dictionary["payload"] as? [String: Any],
          let model = payload["model"] as? String
        {
          currentModel = model
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
              lineNumber: lineNumber,
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
    let metadataID = sessionIdentifier(payload: payload, object: object)
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
      ?? identifier(in: payload, keys: ["session_id", "sessionId"])
      ?? identifier(in: object, keys: ["session_id", "sessionId"])
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
