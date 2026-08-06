import AISpendCore
import Foundation
import XCTest

@testable import AISpendProviders

final class CodexLogScannerTests: XCTestCase {
  func testFilteredStreamingSkipsIrrelevantLineAndPreservesRelevantLineNumbers() throws {
    let root = try emptyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("filtered.jsonl")
    let lines = [
      String(repeating: "x", count: 65_536),
      #"{"timestamp":"2026-06-12T10:44:59Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}"#,
      #"{"timestamp":"2026-06-12T10:45:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0}}}}"#,
    ]
    try writeCodexSession(to: file, lines: lines)
    let recorder = CodexDeepScanLineRecorder()

    let result = try scanCodexRoot(
      root,
      onDeepScanLine: { _, lineNumber in
        recorder.record(lineNumber)
      })

    XCTAssertEqual(recorder.lineNumbers, [2, 3])
    XCTAssertEqual(result.records.first?.estimate?.inputTokens, 100)
    XCTAssertTrue(result.diagnostics.isEmpty)
  }

  func testFilteredStreamingRethrowsCancellationDuringDeliveredLine() async throws {
    let root = try emptyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("cancel.jsonl")
    try writeCodexSession(
      to: file,
      lines: [#"{"type":"turn_context"}"#, #"{"type":"token_count"}"#]
    )
    let task = Task {
      try LocalLogScanner.scanFile(
        file: file,
        relativeTo: root,
        markerBytes: [Data(#""turn_context""#.utf8), Data(#""token_count""#.utf8)]
      ) { _, _ in
        withUnsafeCurrentTask { $0?.cancel() }
      }
    }

    do {
      try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      XCTAssertTrue(true)
    } catch {
      XCTFail("Expected CancellationError, got \(error)")
    }
  }

  func testCumulativeTotalReconcilesEarlierLastOnlyUsage() throws {
    let result = try scanCodexLines([
      #"{"timestamp":"2026-06-12T10:44:59Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}"#,
      #"{"timestamp":"2026-06-12T10:45:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0}}}}"#,
      #"{"timestamp":"2026-06-12T10:45:01Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":150,"cached_input_tokens":0,"output_tokens":0}}}}"#,
    ])

    XCTAssertEqual(result.records.first?.estimate?.inputTokens, 150)
    XCTAssertTrue(result.diagnostics.isEmpty)
  }

  func testLastOnlyCounterOverflowFailsClosedWithoutCrashing() throws {
    let result = try scanCodexLines([
      #"{"timestamp":"2026-06-12T10:44:59Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}"#,
      #"{"timestamp":"2026-06-12T10:45:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\#(Int.max),"cached_input_tokens":0,"output_tokens":0}}}}"#,
      #"{"timestamp":"2026-06-12T10:45:01Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":0}}}}"#,
    ])

    XCTAssertTrue(result.records.isEmpty)
    XCTAssertEqual(result.diagnostics, [.sourceUnavailable(file: "session.jsonl")])
  }

  func testInterleavedCounterGrowthIsContainedByHighWatermark() throws {
    let result = try scanCodexLines([
      #"{"timestamp":"2026-06-12T10:44:59Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}"#,
      #"{"timestamp":"2026-06-12T10:45:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0}}}}"#,
      #"{"timestamp":"2026-06-12T10:45:01Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":40,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":40,"cached_input_tokens":0,"output_tokens":0}}}}"#,
      #"{"timestamp":"2026-06-12T10:45:02Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":70,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":110,"cached_input_tokens":0,"output_tokens":0}}}}"#,
    ])

    XCTAssertEqual(result.records.first?.estimate?.inputTokens, 110)
    XCTAssertTrue(result.diagnostics.isEmpty)
  }

  func testWhitespaceForkIdentifierDoesNotSuppressRootSessionUsage() throws {
    let result = try scanCodexLines([
      #"{"timestamp":"2026-06-12T10:44:59Z","type":"session_meta","payload":{"id":"root-session","forked_from_id":"   "}}"#,
      #"{"timestamp":"2026-06-12T10:44:59Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}"#,
      #"{"timestamp":"2026-06-12T10:45:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0}}}}"#,
    ])

    XCTAssertEqual(result.records.first?.estimate?.inputTokens, 100)
    XCTAssertTrue(result.diagnostics.isEmpty)
  }

  func testDesktopChildrenWithSharedSessionIDCountIndependentlyByPayloadID() throws {
    let root = try emptyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeCodexSession(
      to: root.appendingPathComponent("root.jsonl"),
      lines: [
        #"{"timestamp":"2026-06-12T10:44:00Z","type":"session_meta","payload":{"session_id":"desktop-root","id":"desktop-root"}}"#,
        #"{"timestamp":"2026-06-12T10:44:00Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}"#,
        #"{"timestamp":"2026-06-12T10:45:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0}}}}"#,
      ]
    )
    try writeCodexSession(
      to: root.appendingPathComponent("child-a.jsonl"),
      lines: [
        #"{"timestamp":"2026-06-12T10:46:00Z","type":"session_meta","payload":{"session_id":"desktop-root","id":"desktop-child-a","source":{"subagent":{"thread_spawn":{"parent_thread_id":"desktop-root"}}}}}"#,
        #"{"timestamp":"2026-06-12T10:46:00Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}"#,
        #"{"timestamp":"2026-06-12T10:46:01Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":20,"cached_input_tokens":0,"output_tokens":0}}}}"#,
      ]
    )
    try writeCodexSession(
      to: root.appendingPathComponent("child-b.jsonl"),
      lines: [
        #"{"timestamp":"2026-06-12T10:47:00Z","type":"session_meta","payload":{"session_id":"desktop-root","id":"desktop-child-b","source":{"subagent":{"thread_spawn":{"parent_thread_id":"desktop-root"}}}}}"#,
        #"{"timestamp":"2026-06-12T10:47:00Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}"#,
        #"{"timestamp":"2026-06-12T10:47:01Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":30,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":30,"cached_input_tokens":0,"output_tokens":0}}}}"#,
      ]
    )

    let result = try scanCodexRoot(root)

    XCTAssertEqual(result.records.count, 1)
    XCTAssertEqual(result.records.first?.estimate?.inputTokens, 150)
    XCTAssertTrue(result.diagnostics.isEmpty)
  }

  func testLegacySessionIDMetadataResolvesForkedParent() throws {
    let root = try emptyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeCodexSession(
      to: root.appendingPathComponent("parent.jsonl"),
      lines: [
        #"{"timestamp":"2026-06-12T10:44:00Z","type":"session_meta","payload":{"session_id":"legacy-parent"}}"#,
        #"{"timestamp":"2026-06-12T10:44:00Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}"#,
        #"{"timestamp":"2026-06-12T10:45:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0}}}}"#,
      ]
    )
    try writeCodexSession(
      to: root.appendingPathComponent("child.jsonl"),
      lines: [
        #"{"timestamp":"2026-06-12T10:46:00Z","type":"session_meta","payload":{"session_id":"legacy-child","forked_from_id":"legacy-parent","source":{"subagent":{"thread_spawn":{"parent_thread_id":"legacy-parent"}}}}}"#,
        #"{"timestamp":"2026-06-12T10:46:00Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}"#,
        #"{"timestamp":"2026-06-12T10:46:01Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0}}}}"#,
        #"{"timestamp":"2026-06-12T10:46:02Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":25,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":125,"cached_input_tokens":0,"output_tokens":0}}}}"#,
      ]
    )

    let result = try scanCodexRoot(root)

    XCTAssertEqual(result.records.first?.estimate?.inputTokens, 125)
    XCTAssertTrue(result.diagnostics.isEmpty)
  }

  func testWhitespacePayloadSessionIDFallsThroughToPayloadSessionId() throws {
    let root = try emptyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeCodexSession(
      to: root.appendingPathComponent("parent.jsonl"),
      lines: [
        #"{"timestamp":"2026-06-12T10:44:00Z","type":"session_meta","payload":{"session_id":"   ","sessionId":"payload-parent"}}"#,
        #"{"timestamp":"2026-06-12T10:44:00Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}"#,
        #"{"timestamp":"2026-06-12T10:45:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0}}}}"#,
      ]
    )
    try writeCodexSession(
      to: root.appendingPathComponent("child.jsonl"),
      lines: [
        #"{"timestamp":"2026-06-12T10:46:00Z","type":"session_meta","payload":{"session_id":"   ","sessionId":"payload-child","forked_from_id":"payload-parent","source":{"subagent":{"thread_spawn":{"parent_thread_id":"payload-parent"}}}}}"#,
        #"{"timestamp":"2026-06-12T10:46:00Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}"#,
        #"{"timestamp":"2026-06-12T10:46:01Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":0}}}}"#,
      ]
    )

    let result = try scanCodexRoot(root)

    XCTAssertEqual(result.records.first?.estimate?.inputTokens, 110)
    XCTAssertTrue(result.diagnostics.isEmpty)
  }

  func testWhitespaceTopLevelSessionIDFallsThroughToTopLevelSessionId() throws {
    let root = try emptyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeCodexSession(
      to: root.appendingPathComponent("parent.jsonl"),
      lines: [
        #"{"timestamp":"2026-06-12T10:44:00Z","type":"session_meta","session_id":"   ","sessionId":"top-level-parent"}"#,
        #"{"timestamp":"2026-06-12T10:44:00Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}"#,
        #"{"timestamp":"2026-06-12T10:45:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0}}}}"#,
      ]
    )
    try writeCodexSession(
      to: root.appendingPathComponent("child.jsonl"),
      lines: [
        #"{"timestamp":"2026-06-12T10:46:00Z","type":"session_meta","session_id":"   ","sessionId":"top-level-child","payload":{"forked_from_id":"top-level-parent","source":{"subagent":{"thread_spawn":{"parent_thread_id":"top-level-parent"}}}}}"#,
        #"{"timestamp":"2026-06-12T10:46:00Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}"#,
        #"{"timestamp":"2026-06-12T10:46:01Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":0}}}}"#,
      ]
    )

    let result = try scanCodexRoot(root)

    XCTAssertEqual(result.records.first?.estimate?.inputTokens, 110)
    XCTAssertTrue(result.diagnostics.isEmpty)
  }

  func testWhitespacePayloadIDFallsThroughToTopLevelIDBeforeSessionID() throws {
    let root = try emptyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeCodexSession(
      to: root.appendingPathComponent("parent.jsonl"),
      lines: [
        #"{"timestamp":"2026-06-12T10:44:00Z","type":"session_meta","payload":{"id":"parent"}}"#,
        #"{"timestamp":"2026-06-12T10:44:00Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}"#,
        #"{"timestamp":"2026-06-12T10:45:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0}}}}"#,
      ]
    )
    try writeCodexSession(
      to: root.appendingPathComponent("child.jsonl"),
      lines: [
        #"{"timestamp":"2026-06-12T10:46:00Z","type":"session_meta","id":"top-level-child","payload":{"id":"  ","session_id":"parent","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent"}}}}}"#,
        #"{"timestamp":"2026-06-12T10:46:00Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}"#,
        #"{"timestamp":"2026-06-12T10:46:01Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":0}}}}"#,
      ]
    )

    let result = try scanCodexRoot(root)

    XCTAssertEqual(result.records.first?.estimate?.inputTokens, 60)
    XCTAssertTrue(result.diagnostics.isEmpty)
  }

  func testForkResolvesParentWhoseSessionIdentifierIsTopLevel() throws {
    let root = try emptyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeCodexSession(
      to: root.appendingPathComponent("parent.jsonl"),
      lines: [
        #"{"timestamp":"2026-06-12T10:44:00Z","type":"session_meta","id":"top-level-parent"}"#,
        #"{"timestamp":"2026-06-12T10:44:00Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}"#,
        #"{"timestamp":"2026-06-12T10:45:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0}}}}"#,
      ]
    )
    try writeCodexSession(
      to: root.appendingPathComponent("child.jsonl"),
      lines: [
        #"{"timestamp":"2026-06-12T10:46:00Z","type":"session_meta","payload":{"id":"child-session","forked_from_id":"top-level-parent"}}"#,
        #"{"timestamp":"2026-06-12T10:46:00Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}"#,
        #"{"timestamp":"2026-06-12T10:46:01Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0}}}}"#,
        #"{"timestamp":"2026-06-12T10:46:02Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":150,"cached_input_tokens":0,"output_tokens":0}}}}"#,
      ]
    )
    let calendar = utcCalendar()
    let window = try MonthWindow.current(
      containing: isoDate("2026-06-15T00:00:00Z"),
      calendar: calendar
    )

    let result = try CodexLogScanner(
      sessionRoots: [root],
      priceCatalog: try PriceCatalog.bundled(),
      calendar: calendar
    ).scan(window: window, fetchedAt: window.end)

    XCTAssertEqual(result.records.first?.estimate?.inputTokens, 150)
    XCTAssertTrue(result.diagnostics.isEmpty)
  }

  func testRepeatedFlatTotalSnapshotWithNonzeroLastUsageContributesZero() throws {
    let root = try emptyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeCodexSession(
      to: root.appendingPathComponent("flat-total.jsonl"),
      lines: [
        #"{"timestamp":"2026-06-12T10:44:59Z","type":"session_meta","payload":{"id":"flat-session"}}"#,
        #"{"timestamp":"2026-06-12T10:44:59Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}"#,
        #"{"timestamp":"2026-06-12T10:45:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"output_tokens":0}}}}"#,
        #"{"timestamp":"2026-06-12T10:45:01Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"output_tokens":0}}}}"#,
      ]
    )
    let calendar = utcCalendar()
    let window = try MonthWindow.current(
      containing: isoDate("2026-06-15T00:00:00Z"),
      calendar: calendar
    )

    let result = try CodexLogScanner(
      sessionRoots: [root],
      priceCatalog: try PriceCatalog.bundled(),
      calendar: calendar
    ).scan(window: window, fetchedAt: window.end)

    XCTAssertEqual(result.records.count, 1)
    XCTAssertEqual(result.records.first?.estimate?.inputTokens, 1_000)
    XCTAssertEqual(result.records.first?.estimate?.cachedInputTokens, 0)
    XCTAssertEqual(result.records.first?.estimate?.outputTokens, 0)
    XCTAssertTrue(result.diagnostics.isEmpty)
  }

  func testForkedSessionCountsOnlyGrowthBeyondCopiedParentPrefix() throws {
    let root = try emptyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeCodexSession(
      to: root.appendingPathComponent("parent.jsonl"),
      lines: [
        #"{"timestamp":"2026-06-12T10:44:00Z","type":"session_meta","payload":{"id":"parent-session"}}"#,
        #"{"timestamp":"2026-06-12T10:44:00Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}"#,
        #"{"timestamp":"2026-06-12T10:45:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"output_tokens":0}}}}"#,
        #"{"timestamp":"2026-06-12T10:45:01Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":200,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":1200,"cached_input_tokens":0,"output_tokens":0}}}}"#,
      ]
    )
    try writeCodexSession(
      to: root.appendingPathComponent("child.jsonl"),
      lines: [
        #"{"timestamp":"2026-06-12T10:46:00Z","type":"session_meta","payload":{"id":"child-session","forked_from_id":"parent-session","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent-session"}}}}}"#,
        #"{"timestamp":"2026-06-12T10:46:00Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}"#,
        #"{"timestamp":"2026-06-12T10:46:01Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"output_tokens":0}}}}"#,
        #"{"timestamp":"2026-06-12T10:46:02Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":200,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":1200,"cached_input_tokens":0,"output_tokens":0}}}}"#,
        #"{"timestamp":"2026-06-12T10:46:03Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":1250,"cached_input_tokens":0,"output_tokens":0}}}}"#,
      ]
    )
    let calendar = utcCalendar()
    let window = try MonthWindow.current(
      containing: isoDate("2026-06-15T00:00:00Z"),
      calendar: calendar
    )

    let result = try CodexLogScanner(
      sessionRoots: [root],
      priceCatalog: try PriceCatalog.bundled(),
      calendar: calendar
    ).scan(window: window, fetchedAt: window.end)

    XCTAssertEqual(result.records.count, 1)
    XCTAssertEqual(result.records.first?.estimate?.inputTokens, 1_250)
    XCTAssertEqual(result.records.first?.estimate?.cachedInputTokens, 0)
    XCTAssertEqual(result.records.first?.estimate?.outputTokens, 0)
    XCTAssertTrue(result.diagnostics.isEmpty)
  }

  func testForkedSubagentWithIndependentCounterCountsFromZero() throws {
    let root = try emptyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeCodexSession(
      to: root.appendingPathComponent("parent.jsonl"),
      lines: [
        #"{"timestamp":"2026-06-12T10:44:00Z","type":"session_meta","payload":{"id":"parent-session"}}"#,
        #"{"timestamp":"2026-06-12T10:44:00Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}"#,
        #"{"timestamp":"2026-06-12T10:45:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"output_tokens":0}}}}"#,
      ]
    )
    try writeCodexSession(
      to: root.appendingPathComponent("child.jsonl"),
      lines: [
        #"{"timestamp":"2026-06-12T10:46:00Z","type":"session_meta","payload":{"id":"independent-child","forked_from_id":"parent-session","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent-session"}}}}}"#,
        #"{"timestamp":"2026-06-12T10:46:00Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}"#,
        #"{"timestamp":"2026-06-12T10:46:01Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":0}}}}"#,
        #"{"timestamp":"2026-06-12T10:46:02Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":20,"cached_input_tokens":0,"output_tokens":0}}}}"#,
      ]
    )

    let result = try scanCodexRoot(root)

    XCTAssertEqual(result.records.first?.estimate?.inputTokens, 1_020)
    XCTAssertTrue(result.diagnostics.isEmpty)
  }

  func testIndependentSubagentRemainsIndependentAfterSurpassingParentTotal() throws {
    let root = try emptyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeCodexSession(
      to: root.appendingPathComponent("parent.jsonl"),
      lines: [
        #"{"timestamp":"2026-06-12T10:44:00Z","type":"session_meta","payload":{"id":"parent-session"}}"#,
        #"{"timestamp":"2026-06-12T10:44:00Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}"#,
        #"{"timestamp":"2026-06-12T10:45:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"output_tokens":0}}}}"#,
      ]
    )
    try writeCodexSession(
      to: root.appendingPathComponent("child.jsonl"),
      lines: [
        #"{"timestamp":"2026-06-12T10:46:00Z","type":"session_meta","payload":{"id":"independent-child","forked_from_id":"parent-session","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent-session"}}}}}"#,
        #"{"timestamp":"2026-06-12T10:46:00Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}"#,
        #"{"timestamp":"2026-06-12T10:46:01Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":0}}}}"#,
        #"{"timestamp":"2026-06-12T10:46:02Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1190,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":1200,"cached_input_tokens":0,"output_tokens":0}}}}"#,
      ]
    )

    let result = try scanCodexRoot(root)

    XCTAssertEqual(result.records.first?.estimate?.inputTokens, 2_200)
    XCTAssertTrue(result.diagnostics.isEmpty)
  }

  func testCurrentMonthForkResolvesParentFileModifiedBeforeWindow() throws {
    let root = try emptyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let parent = root.appendingPathComponent("old-parent.jsonl")
    try writeCodexSession(
      to: parent,
      lines: [
        #"{"timestamp":"2026-05-31T10:44:00Z","type":"session_meta","payload":{"id":"old-parent"}}"#,
        #"{"timestamp":"2026-05-31T10:44:00Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}"#,
        #"{"timestamp":"2026-05-31T10:45:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0}}}}"#,
      ]
    )
    try setModificationDate(parent, to: isoDate("2026-05-31T12:00:00Z"))
    try writeCodexSession(
      to: root.appendingPathComponent("child.jsonl"),
      lines: [
        #"{"timestamp":"2026-06-12T10:46:00Z","type":"session_meta","payload":{"id":"child-session","forked_from_id":"old-parent"}}"#,
        #"{"timestamp":"2026-06-12T10:46:00Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}"#,
        #"{"timestamp":"2026-06-12T10:46:01Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0}}}}"#,
        #"{"timestamp":"2026-06-12T10:46:02Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":150,"cached_input_tokens":0,"output_tokens":0}}}}"#,
      ]
    )

    let result = try scanCodexRoot(root)

    XCTAssertEqual(result.records.first?.estimate?.inputTokens, 50)
    XCTAssertTrue(result.diagnostics.isEmpty)
  }

  func testFullScansEachCandidateAndReachableHistoricalParentOnlyOnce() throws {
    let root = try emptyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let parent = root.appendingPathComponent("old-parent.jsonl")
    try writeCodexSession(
      to: parent,
      lines: [
        #"{"timestamp":"2026-05-31T10:44:00Z","type":"session_meta","payload":{"id":"reachable-parent"}}"#,
        #"{"timestamp":"2026-05-31T10:45:00Z","type":"event_msg","payload":{"type":"token_count","model":"gpt-5.3-codex","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0}}}}"#,
      ]
    )
    try setModificationDate(parent, to: isoDate("2026-05-31T12:00:00Z"))
    let unrelated = root.appendingPathComponent("unrelated-old.jsonl")
    try writeCodexSession(
      to: unrelated,
      lines: [
        #"{"timestamp":"2026-05-30T10:44:00Z","type":"session_meta","payload":{"id":"unrelated-session"}}"#,
        #"{"timestamp":"2026-05-30T10:45:00Z","type":"event_msg","payload":{"type":"token_count","model":"gpt-5.3-codex","info":{"last_token_usage":{"input_tokens":900,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":900,"cached_input_tokens":0,"output_tokens":0}}}}"#,
      ]
    )
    try setModificationDate(unrelated, to: isoDate("2026-05-30T12:00:00Z"))
    try writeCodexSession(
      to: root.appendingPathComponent("child.jsonl"),
      lines: [
        #"{"timestamp":"2026-06-12T10:46:00Z","type":"session_meta","payload":{"id":"child-session","forked_from_id":"reachable-parent"}}"#,
        #"{"timestamp":"2026-06-12T10:46:00Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}"#,
        #"{"timestamp":"2026-06-12T10:46:01Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0}}}}"#,
        #"{"timestamp":"2026-06-12T10:46:02Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":150,"cached_input_tokens":0,"output_tokens":0}}}}"#,
      ]
    )
    let recorder = CodexDeepScanRecorder()
    let calendar = utcCalendar()
    let window = try MonthWindow.current(
      containing: isoDate("2026-06-15T00:00:00Z"),
      calendar: calendar
    )

    let result = try CodexLogScanner(
      sessionRoots: [root],
      priceCatalog: try PriceCatalog.bundled(),
      calendar: calendar,
      onFullFileScan: { recorder.record($0.lastPathComponent) }
    ).scan(window: window, fetchedAt: window.end)

    XCTAssertEqual(result.records.first?.estimate?.inputTokens, 50)
    XCTAssertEqual(recorder.count(for: "child.jsonl"), 1)
    XCTAssertEqual(recorder.count(for: "old-parent.jsonl"), 1)
    XCTAssertEqual(recorder.count(for: "unrelated-old.jsonl"), 0)
    XCTAssertTrue(result.diagnostics.isEmpty)
  }

  func testOverlappingRootsScanCanonicalCandidateOnlyOnce() throws {
    let root = try emptyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeCodexSession(
      to: root.appendingPathComponent("session.jsonl"),
      lines: [
        #"{"timestamp":"2026-06-12T10:44:00Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}"#,
        #"{"timestamp":"2026-06-12T10:45:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0}}}}"#,
      ]
    )
    let recorder = CodexDeepScanRecorder()
    let calendar = utcCalendar()
    let window = try MonthWindow.current(
      containing: isoDate("2026-06-15T00:00:00Z"),
      calendar: calendar
    )

    let result = try CodexLogScanner(
      sessionRoots: [root, root],
      priceCatalog: try PriceCatalog.bundled(),
      calendar: calendar,
      onFullFileScan: { recorder.record($0.lastPathComponent) }
    ).scan(window: window, fetchedAt: window.end)

    XCTAssertEqual(recorder.count(for: "session.jsonl"), 1)
    XCTAssertEqual(result.records.count, 1)
    XCTAssertEqual(result.records.first?.estimate?.inputTokens, 100)
    XCTAssertTrue(result.diagnostics.isEmpty)
  }

  func testCurrentCandidateThatIsAlsoParentIsScannedOnlyOnce() throws {
    let root = try emptyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeCodexSession(
      to: root.appendingPathComponent("parent.jsonl"),
      lines: [
        #"{"timestamp":"2026-06-12T10:44:00Z","type":"session_meta","payload":{"id":"current-parent"}}"#,
        #"{"timestamp":"2026-06-12T10:44:00Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}"#,
        #"{"timestamp":"2026-06-12T10:45:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0}}}}"#,
      ]
    )
    try writeCodexSession(
      to: root.appendingPathComponent("child.jsonl"),
      lines: [
        #"{"timestamp":"2026-06-12T10:46:00Z","type":"session_meta","payload":{"id":"current-child","forked_from_id":"current-parent","source":{"subagent":{"thread_spawn":{"parent_thread_id":"current-parent"}}}}}"#,
        #"{"timestamp":"2026-06-12T10:46:00Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}"#,
        #"{"timestamp":"2026-06-12T10:46:01Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0}}}}"#,
        #"{"timestamp":"2026-06-12T10:46:02Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":150,"cached_input_tokens":0,"output_tokens":0}}}}"#,
      ]
    )
    let recorder = CodexDeepScanRecorder()
    let calendar = utcCalendar()
    let window = try MonthWindow.current(
      containing: isoDate("2026-06-15T00:00:00Z"),
      calendar: calendar
    )

    let result = try CodexLogScanner(
      sessionRoots: [root],
      priceCatalog: try PriceCatalog.bundled(),
      calendar: calendar,
      onFullFileScan: { recorder.record($0.lastPathComponent) }
    ).scan(window: window, fetchedAt: window.end)

    XCTAssertEqual(recorder.count(for: "parent.jsonl"), 1)
    XCTAssertEqual(recorder.count(for: "child.jsonl"), 1)
    XCTAssertEqual(result.records.first?.estimate?.inputTokens, 150)
    XCTAssertTrue(result.diagnostics.isEmpty)
  }

  func testDuplicateParentSessionIdentifiersFailClosed() throws {
    let root = try emptyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let firstParent = root.appendingPathComponent("a-parent.jsonl")
    try writeCodexSession(
      to: firstParent,
      lines: [
        #"{"timestamp":"2026-05-30T10:44:00Z","type":"session_meta","payload":{"id":"duplicate-parent"}}"#,
        #"{"timestamp":"2026-05-30T10:45:00Z","type":"event_msg","payload":{"type":"token_count","model":"gpt-5.3-codex","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0}}}}"#,
      ]
    )
    try setModificationDate(firstParent, to: isoDate("2026-05-30T12:00:00Z"))
    let secondParent = root.appendingPathComponent("b-parent.jsonl")
    try writeCodexSession(
      to: secondParent,
      lines: [
        #"{"timestamp":"2026-05-31T10:44:00Z","type":"session_meta","payload":{"id":"duplicate-parent"}}"#,
        #"{"timestamp":"2026-05-31T10:45:00Z","type":"event_msg","payload":{"type":"token_count","model":"gpt-5.3-codex","info":{"last_token_usage":{"input_tokens":200,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":200,"cached_input_tokens":0,"output_tokens":0}}}}"#,
      ]
    )
    try setModificationDate(secondParent, to: isoDate("2026-05-31T12:00:00Z"))
    try writeCodexSession(
      to: root.appendingPathComponent("child.jsonl"),
      lines: [
        #"{"timestamp":"2026-06-12T10:46:00Z","type":"session_meta","payload":{"id":"child-session","forked_from_id":"duplicate-parent"}}"#,
        #"{"timestamp":"2026-06-12T10:46:00Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}"#,
        #"{"timestamp":"2026-06-12T10:46:01Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0}}}}"#,
        #"{"timestamp":"2026-06-12T10:46:02Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":150,"cached_input_tokens":0,"output_tokens":0}}}}"#,
      ]
    )

    let result = try scanCodexRoot(root)

    XCTAssertTrue(result.records.isEmpty)
    XCTAssertEqual(result.diagnostics, [.sourceUnavailable(file: "child.jsonl")])
  }

  func testDuplicateParentIdentifierBeyondMetadataPrefixFailsClosed() throws {
    let root = try emptyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let oldParent = root.appendingPathComponent("a-old-parent.jsonl")
    try writeCodexSession(
      to: oldParent,
      lines: [
        #"{"timestamp":"2026-05-31T10:44:00Z","type":"session_meta","payload":{"id":"duplicate-parent"}}"#,
        #"{"timestamp":"2026-05-31T10:45:00Z","type":"event_msg","payload":{"type":"token_count","model":"gpt-5.3-codex","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0}}}}"#,
      ]
    )
    try setModificationDate(oldParent, to: isoDate("2026-05-31T12:00:00Z"))
    try writeCodexSession(
      to: root.appendingPathComponent("z-late-parent.jsonl"),
      lines: [
        String(repeating: "x", count: 70_000),
        #"{"timestamp":"2026-06-12T10:44:00Z","type":"session_meta","payload":{"id":"duplicate-parent"}}"#,
      ]
    )
    try writeCodexSession(
      to: root.appendingPathComponent("child.jsonl"),
      lines: [
        #"{"timestamp":"2026-06-12T10:46:00Z","type":"session_meta","payload":{"id":"child-session","forked_from_id":"duplicate-parent"}}"#,
        #"{"timestamp":"2026-06-12T10:46:00Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}"#,
        #"{"timestamp":"2026-06-12T10:46:01Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0}}}}"#,
        #"{"timestamp":"2026-06-12T10:46:02Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":150,"cached_input_tokens":0,"output_tokens":0}}}}"#,
      ]
    )

    let result = try scanCodexRoot(root)

    XCTAssertTrue(result.records.isEmpty)
    XCTAssertEqual(result.diagnostics, [.sourceUnavailable(file: "child.jsonl")])
  }

  func testCumulativeChildResolvesLastOnlyParentBaseline() throws {
    let root = try emptyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeCodexSession(
      to: root.appendingPathComponent("parent.jsonl"),
      lines: [
        #"{"timestamp":"2026-06-12T10:44:00Z","type":"session_meta","payload":{"id":"legacy-parent"}}"#,
        #"{"timestamp":"2026-06-12T10:44:00Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}"#,
        #"{"timestamp":"2026-06-12T10:45:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0}}}}"#,
      ]
    )
    try writeCodexSession(
      to: root.appendingPathComponent("child.jsonl"),
      lines: [
        #"{"timestamp":"2026-06-12T10:46:00Z","type":"session_meta","payload":{"id":"child-session","forked_from_id":"legacy-parent"}}"#,
        #"{"timestamp":"2026-06-12T10:46:00Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}"#,
        #"{"timestamp":"2026-06-12T10:46:01Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0}}}}"#,
        #"{"timestamp":"2026-06-12T10:46:02Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":150,"cached_input_tokens":0,"output_tokens":0}}}}"#,
      ]
    )

    let result = try scanCodexRoot(root)

    XCTAssertEqual(result.records.first?.estimate?.inputTokens, 150)
    XCTAssertTrue(result.diagnostics.isEmpty)
  }

  func testForkWithResolvedParentButNoUsageBaselineFailsClosed() throws {
    let root = try emptyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeCodexSession(
      to: root.appendingPathComponent("parent.jsonl"),
      lines: [
        #"{"timestamp":"2026-06-12T10:44:00Z","type":"session_meta","payload":{"id":"metadata-only-parent"}}"#
      ]
    )
    try writeCodexSession(
      to: root.appendingPathComponent("child.jsonl"),
      lines: [
        #"{"timestamp":"2026-06-12T10:46:00Z","type":"session_meta","payload":{"id":"compact-child","forked_from_id":"metadata-only-parent"}}"#,
        #"{"timestamp":"2026-06-12T10:46:00Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}"#,
        #"{"timestamp":"2026-06-12T10:46:01Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"output_tokens":0}}}}"#,
      ]
    )

    let result = try scanCodexRoot(root)

    XCTAssertTrue(result.records.isEmpty)
    XCTAssertEqual(result.diagnostics, [.sourceUnavailable(file: "child.jsonl")])
  }

  func testScanUsesStableCandidateSnapshotAcrossLineageBoundary() throws {
    let root = try emptyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeCodexSession(
      to: root.appendingPathComponent("stable.jsonl"),
      lines: [
        #"{"timestamp":"2026-06-12T10:44:00Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}"#,
        #"{"timestamp":"2026-06-12T10:45:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0}}}}"#,
      ]
    )
    let changed = root.appendingPathComponent("changed.jsonl")
    try writeCodexSession(
      to: changed,
      lines: [
        #"{"timestamp":"2026-06-12T10:44:00Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}"#,
        #"{"timestamp":"2026-06-12T10:45:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0}}}}"#,
      ]
    )
    let late = root.appendingPathComponent("late.jsonl")
    let calendar = utcCalendar()
    let window = try MonthWindow.current(
      containing: isoDate("2026-06-15T00:00:00Z"),
      calendar: calendar
    )
    let scanner = CodexLogScanner(
      sessionRoots: [root],
      priceCatalog: try PriceCatalog.bundled(),
      calendar: calendar,
      afterLineageScan: {
        try appendCodexLine(
          #"{"timestamp":"2026-06-12T10:46:00Z","type":"session_meta","payload":{"id":"changed-child","forked_from_id":"missing-parent"}}"#,
          to: changed
        )
        try writeCodexSession(
          to: late,
          lines: [
            #"{"timestamp":"2026-06-12T10:46:00Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}"#,
            #"{"timestamp":"2026-06-12T10:46:01Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0}}}}"#,
          ]
        )
      }
    )

    let result = try scanner.scan(window: window, fetchedAt: window.end)

    XCTAssertEqual(result.records.first?.estimate?.inputTokens, 50)
    XCTAssertEqual(result.diagnostics, [.sourceUnavailable(file: "changed.jsonl")])
  }

  func testTransitiveAncestorChangeAfterLineageFailsCandidateClosed() throws {
    let root = try emptyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let grandparent = root.appendingPathComponent("grandparent.jsonl")
    try writeCodexSession(
      to: grandparent,
      lines: [
        #"{"timestamp":"2026-05-30T10:40:00Z","type":"session_meta","payload":{"id":"grandparent"}}"#,
        #"{"timestamp":"2026-05-30T10:41:00Z","type":"event_msg","payload":{"type":"token_count","model":"gpt-5.3-codex","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0}}}}"#,
      ]
    )
    try setModificationDate(grandparent, to: isoDate("2026-05-30T12:00:00Z"))
    let parent = root.appendingPathComponent("parent.jsonl")
    try writeCodexSession(
      to: parent,
      lines: [
        #"{"timestamp":"2026-05-31T10:40:00Z","type":"session_meta","payload":{"id":"parent","forked_from_id":"grandparent","source":{"subagent":{"thread_spawn":{"parent_thread_id":"grandparent"}}}}}"#,
        #"{"timestamp":"2026-05-31T10:41:00Z","type":"event_msg","payload":{"type":"token_count","model":"gpt-5.3-codex","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0}}}}"#,
        #"{"timestamp":"2026-05-31T10:42:00Z","type":"event_msg","payload":{"type":"token_count","model":"gpt-5.3-codex","info":{"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":150,"cached_input_tokens":0,"output_tokens":0}}}}"#,
      ]
    )
    try setModificationDate(parent, to: isoDate("2026-05-31T12:00:00Z"))
    try writeCodexSession(
      to: root.appendingPathComponent("child.jsonl"),
      lines: [
        #"{"timestamp":"2026-06-12T10:40:00Z","type":"session_meta","payload":{"id":"child","forked_from_id":"parent","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent"}}}}}"#,
        #"{"timestamp":"2026-06-12T10:40:00Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}"#,
        #"{"timestamp":"2026-06-12T10:41:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":150,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":150,"cached_input_tokens":0,"output_tokens":0}}}}"#,
        #"{"timestamp":"2026-06-12T10:42:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":200,"cached_input_tokens":0,"output_tokens":0}}}}"#,
      ]
    )
    let calendar = utcCalendar()
    let retentionRecorder = CodexRetentionMetricsRecorder()
    let window = try MonthWindow.current(
      containing: isoDate("2026-06-15T00:00:00Z"),
      calendar: calendar
    )

    let result = try CodexLogScanner(
      sessionRoots: [root],
      priceCatalog: try PriceCatalog.bundled(),
      calendar: calendar,
      afterLineageScan: {
        try appendCodexLine(#"{"type":"changed"}"#, to: grandparent)
      },
      onRetentionMetrics: { retentionRecorder.record($0) }
    ).scan(window: window, fetchedAt: window.end)

    XCTAssertTrue(result.records.isEmpty)
    XCTAssertEqual(result.diagnostics, [.sourceUnavailable(file: "child.jsonl")])
    XCTAssertEqual(
      retentionRecorder.metrics,
      CodexRetentionMetrics(
        scannedFileCount: 3,
        retainedFingerprintCount: 3,
        materializedCandidateSnapshotCount: 0
      )
    )
  }

  func testCandidateMissingDuringLineageScanFailsClosedIfRecreatedBeforeBilling() throws {
    let root = try emptyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeCodexSession(
      to: root.appendingPathComponent("stable.jsonl"),
      lines: [
        #"{"timestamp":"2026-06-12T10:44:00Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}"#,
        #"{"timestamp":"2026-06-12T10:45:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0}}}}"#,
      ]
    )
    let recreated = root.appendingPathComponent("recreated.jsonl")
    let recreatedLines = [
      #"{"timestamp":"2026-06-12T10:44:00Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}"#,
      #"{"timestamp":"2026-06-12T10:45:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0}}}}"#,
    ]
    try writeCodexSession(to: recreated, lines: recreatedLines)
    let calendar = utcCalendar()
    let window = try MonthWindow.current(
      containing: isoDate("2026-06-15T00:00:00Z"),
      calendar: calendar
    )
    let scanner = CodexLogScanner(
      sessionRoots: [root],
      priceCatalog: try PriceCatalog.bundled(),
      calendar: calendar,
      beforeLineageScan: {
        try FileManager.default.removeItem(at: recreated)
      },
      afterLineageScan: {
        try writeCodexSession(to: recreated, lines: recreatedLines)
      }
    )

    let result = try scanner.scan(window: window, fetchedAt: window.end)

    XCTAssertEqual(result.records.first?.estimate?.inputTokens, 50)
    XCTAssertEqual(result.diagnostics, [.sourceUnavailable(file: "recreated.jsonl")])
  }

  func testSkipsIrrelevantLinesBeforeJSONDecoding() throws {
    let root = try emptyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("large-session.jsonl")
    let irrelevant = Data(repeating: 0x78, count: 262_144)
    let usage = Data(
      """
      {"timestamp":"2026-06-12T10:44:59.123Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}
      {"timestamp":"2026-06-12T10:45:00.456Z","type":"event_msg","event_id":"event-1","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"output_tokens":100}}}}

      """.utf8
    )
    var contents = irrelevant
    contents.append(0x0A)
    contents.append(usage)
    try contents.write(to: file)
    try setModificationDate(file)
    let calendar = utcCalendar()
    let window = try MonthWindow.current(
      containing: isoDate("2026-06-15T00:00:00Z"),
      calendar: calendar
    )

    let result = try CodexLogScanner(
      sessionRoots: [root],
      priceCatalog: try PriceCatalog.bundled(),
      calendar: calendar
    ).scan(window: window, fetchedAt: window.end)

    XCTAssertEqual(result.records.count, 1)
    XCTAssertTrue(result.diagnostics.isEmpty)
  }

  func testSinglePassPreservesCandidateMalformedLineDiagnostics() throws {
    let result = try scanCodexLines([
      #"{"timestamp":"2026-06-12T10:44:59Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}"#,
      #"{"type":"event_msg","payload":{"type":"token_count""#,
      #"{"timestamp":"2026-06-12T10:45:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0}}}}"#,
    ])

    XCTAssertEqual(result.records.first?.estimate?.inputTokens, 100)
    XCTAssertEqual(result.diagnostics, [.malformedLine(file: "session.jsonl", line: 2)])
  }

  func testScansStreamsDeduplicatesAndAggregatesOneRecordPerModelDay() throws {
    let root = try fixtureRoot(named: "codex-session")
    defer { try? FileManager.default.removeItem(at: root) }
    let calendar = utcCalendar()
    let window = try MonthWindow.current(
      containing: isoDate("2026-06-15T00:00:00Z"),
      calendar: calendar
    )
    let scanner = CodexLogScanner(
      sessionRoots: [root],
      priceCatalog: try PriceCatalog.bundled(),
      calendar: calendar
    )

    let result = try scanner.scan(
      window: window,
      fetchedAt: isoDate("2026-06-30T12:00:00Z")
    )

    XCTAssertEqual(result.records.count, 1)
    let record = try XCTUnwrap(result.records.first)
    XCTAssertEqual(record.provider, .openAI)
    XCTAssertEqual(record.quality, .estimated)
    XCTAssertEqual(record.model, "gpt-5.3-codex")
    XCTAssertEqual(record.amount, Money(Decimal(string: "2.835")!))
    XCTAssertEqual(record.estimate?.inputTokens, 800_000)
    XCTAssertEqual(record.estimate?.cachedInputTokens, 200_000)
    XCTAssertEqual(record.estimate?.outputTokens, 100_000)
    XCTAssertEqual(record.estimate?.catalogVersion, "2026-07-27")
    XCTAssertTrue(result.diagnostics.isEmpty)
  }

  func testUnknownModelProducesUnavailableDiagnosticAndNoZeroRecord() throws {
    let root = try emptyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("unknown.jsonl")
    try Data(
      """
      {"timestamp":"2026-06-12T10:45:00Z","type":"event_msg","event_id":"unknown-1","payload":{"type":"token_count","model":"future-codex","info":{"last_token_usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":0}}}}

      """.utf8
    ).write(to: file)
    try setModificationDate(file)
    let calendar = utcCalendar()
    let window = try MonthWindow.current(
      containing: isoDate("2026-06-15T00:00:00Z"),
      calendar: calendar
    )

    let result = try CodexLogScanner(
      sessionRoots: [root],
      priceCatalog: try PriceCatalog.bundled(),
      calendar: calendar
    ).scan(window: window, fetchedAt: window.end)

    XCTAssertTrue(result.records.isEmpty)
    XCTAssertEqual(result.diagnostics, [.unavailableEstimate(model: "future-codex")])
  }

  func testSyntheticEventIdentityUsesStableFilePositionWithoutCollisions() throws {
    let first = try codexRootWithRepeatedUsage()
    let second = try codexRootWithRepeatedUsage()
    defer {
      try? FileManager.default.removeItem(at: first)
      try? FileManager.default.removeItem(at: second)
    }
    let calendar = utcCalendar()
    let window = try MonthWindow.current(
      containing: isoDate("2026-06-15T00:00:00Z"),
      calendar: calendar
    )
    let catalog = try PriceCatalog.bundled()

    let firstResult = try CodexLogScanner(
      sessionRoots: [first],
      priceCatalog: catalog,
      calendar: calendar
    ).scan(window: window, fetchedAt: window.end)
    let secondResult = try CodexLogScanner(
      sessionRoots: [second],
      priceCatalog: catalog,
      calendar: calendar
    ).scan(window: window, fetchedAt: window.end)

    XCTAssertEqual(firstResult.records.first?.amount, Money(Decimal(string: "5.67")!))
    XCTAssertEqual(
      firstResult.records.first?.observationID,
      secondResult.records.first?.observationID
    )
  }
}

func fixtureRoot(named fixture: String) throws -> URL {
  let root = try emptyRoot()
  let source = try XCTUnwrap(
    Bundle.module.url(
      forResource: fixture,
      withExtension: "jsonl",
      subdirectory: "Fixtures"
    )
  )
  let destination = root.appendingPathComponent("\(fixture).jsonl")
  try FileManager.default.copyItem(at: source, to: destination)
  try setModificationDate(destination)
  return root
}

func emptyRoot() throws -> URL {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root
}

func setModificationDate(
  _ url: URL,
  to date: Date = isoDate("2026-06-30T00:00:00Z")
) throws {
  try FileManager.default.setAttributes(
    [.modificationDate: date],
    ofItemAtPath: url.path
  )
}

private func codexRootWithRepeatedUsage() throws -> URL {
  let root = try emptyRoot()
  let file = root.appendingPathComponent("repeated.jsonl")
  try Data(
    """
    {"timestamp":"2026-06-12T10:44:59Z","type":"turn_context","payload":{"turn_id":"sanitized-turn-1","model":"gpt-5.3-codex"}}
    {"timestamp":"2026-06-12T10:45:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000000,"cached_input_tokens":200000,"output_tokens":100000}}}}
    {"timestamp":"2026-06-12T10:45:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000000,"cached_input_tokens":200000,"output_tokens":100000}}}}

    """.utf8
  ).write(to: file)
  try setModificationDate(file)
  return root
}

private func writeCodexSession(to file: URL, lines: [String]) throws {
  try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
  try setModificationDate(file)
}

private func appendCodexLine(_ line: String, to file: URL) throws {
  let handle = try FileHandle(forWritingTo: file)
  defer { try? handle.close() }
  try handle.seekToEnd()
  try handle.write(contentsOf: Data((line + "\n").utf8))
}

private func scanCodexLines(_ lines: [String]) throws -> LocalLogScanResult {
  let root = try emptyRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  try writeCodexSession(to: root.appendingPathComponent("session.jsonl"), lines: lines)
  return try scanCodexRoot(root)
}

private func scanCodexRoot(
  _ root: URL,
  onDeepScanLine: @escaping @Sendable (Data, Int) -> Void = { _, _ in }
) throws -> LocalLogScanResult {
  let calendar = utcCalendar()
  let window = try MonthWindow.current(
    containing: isoDate("2026-06-15T00:00:00Z"),
    calendar: calendar
  )
  return try CodexLogScanner(
    sessionRoots: [root],
    priceCatalog: try PriceCatalog.bundled(),
    calendar: calendar,
    onDeepScanLine: onDeepScanLine
  ).scan(window: window, fetchedAt: window.end)
}

private final class CodexDeepScanRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedFileNames: [String] = []

  var fileNames: [String] {
    lock.withLock { recordedFileNames }
  }

  func record(_ fileName: String) {
    lock.withLock { recordedFileNames.append(fileName) }
  }

  func count(for fileName: String) -> Int {
    lock.withLock { recordedFileNames.count { $0 == fileName } }
  }
}

private final class CodexDeepScanLineRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedLineNumbers: [Int] = []

  var lineNumbers: [Int] {
    lock.withLock { recordedLineNumbers }
  }

  func record(_ lineNumber: Int) {
    lock.withLock { recordedLineNumbers.append(lineNumber) }
  }
}

private final class CodexRetentionMetricsRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedMetrics: CodexRetentionMetrics?

  var metrics: CodexRetentionMetrics? {
    lock.withLock { recordedMetrics }
  }

  func record(_ metrics: CodexRetentionMetrics) {
    lock.withLock { recordedMetrics = metrics }
  }
}

func utcCalendar() -> Calendar {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(secondsFromGMT: 0)!
  return calendar
}

func isoDate(_ value: String) -> Date {
  ISO8601DateFormatter().date(from: value)!
}
