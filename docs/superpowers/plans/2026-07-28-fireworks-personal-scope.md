# Fireworks Personal Scope Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Treat a successful Fireworks authenticated-user (`SELF`) cost fallback as normal fresh coverage while retaining a subtle personal-scope diagnostic and preserving warnings for real account failures.

**Architecture:** Keep `ProviderDataCoverage.complete` as the successful result contract. When an `ACCOUNT` request is rejected with 401/403 but `SELF` succeeds, record the account-wide attempt as informational `.unavailable`, record the personal request as succeeded, and return complete provider coverage with authoritative source replacement. Continue using partial coverage only when at least one account remains unavailable after fallback.

**Tech Stack:** Swift 6, Swift concurrency, SwiftData, SwiftUI, XCTest, Swift Package Manager.

## Global Constraints

- A successful `SELF` fallback must not mark Fireworks, the combined total, or budget projections as partial.
- The provider detail diagnostics must still disclose that account-wide permission was unavailable and personal spend was used.
- HTTP 401/403 are the only errors eligible for `SELF` fallback.
- A non-authorization account error, a failed `SELF` request, or a failed normalization must retain existing partial/failed behavior.
- Successful personal-scope refreshes are authoritative for the discovered account set and may prune sources for accounts no longer returned.
- No credential, account resource name, email, or user identifier may be persisted or displayed.
- Claude Code routed through Fireworks must continue to reconcile against the returned actual Fireworks spend without double counting.

---

### Task 1: Make Personal-Scope Fallback a Successful Provider Result

**Files:**
- Modify: `Sources/AISpendProviders/Providers/Fireworks/FireworksAdapter.swift`
- Modify: `Tests/AISpendProvidersTests/FireworksAdapterTests.swift`

**Interfaces:**
- Consumes: `ProviderDataCoverage.complete`, `ProviderSourceAuthority.allProviderSources`, `SourceAttempt.Outcome.unavailable`, and `FireworksCostScope.personal`.
- Produces: a complete `ProviderFetchResult` when every discovered account succeeds through either account or personal scope.

- [ ] **Step 1: Replace the existing partial-fallback assertion with a failing complete-coverage test**

Rename `testAccountAuthorizationFailureFallsBackToPersonalAndMarksPartial` to
`testAccountAuthorizationFailureFallsBackToPersonalAsCompleteCoverage` and
assert the complete contract:

```swift
func testAccountAuthorizationFailureFallsBackToPersonalAsCompleteCoverage() async throws {
  let scopes = FireworksScopeRecorder()
  let adapter = makeAdapter(
    costs: { _, _, scope, _ in
      scopes.append(scope)
      if scope == .account {
        throw ProviderClientError.httpStatus(403)
      }
      return fireworksResult(amount: 1)
    }
  )

  let result = try await adapter.fetch(window: juneWindow())

  XCTAssertEqual(scopes.values, [.account, .personal])
  XCTAssertEqual(result.records.map(\.amount), [Money(1)])
  XCTAssertEqual(result.coverage, .complete)
  XCTAssertEqual(result.sourceAuthority, .allProviderSources)
  XCTAssertEqual(
    result.attempts.map(\.strategyID),
    [
      "fireworks-credential",
      "fireworks-account-discovery",
      "fireworks-account-costs",
      "fireworks-self-costs",
    ]
  )
  guard case .unavailable(let reason) = result.attempts[2].outcome else {
    return XCTFail("Expected informational account-scope outcome")
  }
  XCTAssertEqual(
    reason,
    "Account-wide Fireworks permission unavailable; using personal spend."
  )
  guard case .succeeded(recordCount: 1) = result.attempts[3].outcome else {
    return XCTFail("Expected successful personal-scope outcome")
  }
}
```

- [ ] **Step 2: Run the focused test and verify RED**

```bash
rtk swift test --filter FireworksAdapterTests/testAccountAuthorizationFailureFallsBackToPersonalAsCompleteCoverage
```

Expected: FAIL because the current adapter returns `.partial` and records the
account-wide 403 as `.failed`.

- [ ] **Step 3: Add failing negative regressions**

Retain or add focused tests proving:

```swift
func testNonAuthorizationAccountFailureDoesNotUsePersonalFallback() async throws
```

- HTTP 429 and 500 call only `.account`;
- if another account succeeds, coverage is `.partial`;
- if no account succeeds, coordinator-facing failure semantics remain
  `.complete` with `.refreshedSources`.

Retain or add:

```swift
func testPersonalFallbackFailureRemainsFailedAccount() async throws
```

- 403 calls `.account`, then `.personal`;
- the failed personal attempt is preserved;
- a successful sibling produces `.partial`;
- zero successful accounts retain total-failure semantics and cached-source
  authority.

- [ ] **Step 4: Run the negative tests and verify the existing behavior is captured**

```bash
rtk swift test --filter FireworksAdapterTests
```

Expected: the new complete-coverage test fails; the genuine failure tests pass.

- [ ] **Step 5: Implement the minimal fallback outcome change**

In the nested account query:

1. Do not append a `.failed` account-cost attempt before determining whether
   the error is an authorization failure.
2. For a non-authorization error, append the existing sanitized `.failed`
   account-cost attempt, set `failedAccount = true`, and continue.
3. For HTTP 401/403, append:

```swift
SourceAttempt(
  strategyID: "fireworks-account-costs",
  outcome: .unavailable(
    reason: "Account-wide Fireworks permission unavailable; using personal spend."
  )
)
```

4. Attempt `.personal` exactly once. Preserve the existing sanitized
   `fireworks-self-costs` failure if it fails.
5. Remove `usedPersonalScope`; coverage depends only on `failedAccount`:

```swift
let coverage: ProviderDataCoverage
if everyAccountFailed {
  coverage = .complete
} else if failedAccount {
  coverage = .partial(message: "Some Fireworks account spend is unavailable.")
} else {
  coverage = .complete
}
```

Keep:

```swift
sourceAuthority: coverage == .complete && !everyAccountFailed
  ? .allProviderSources
  : .refreshedSources
```

- [ ] **Step 6: Run adapter tests and verify GREEN**

```bash
rtk swift test --filter FireworksAdapterTests
```

Expected: every adapter test passes; successful personal fallback is complete,
while real failures remain partial or failed.

- [ ] **Step 7: Commit Task 1**

```bash
rtk git add Sources/AISpendProviders/Providers/Fireworks/FireworksAdapter.swift Tests/AISpendProvidersTests/FireworksAdapterTests.swift
rtk git commit -m "fix: treat Fireworks personal spend as complete"
```

---

### Task 2: Align Refresh State, UI Semantics, and Documentation

**Files:**
- Modify: `Tests/AISpendCoreTests/RefreshCoordinatorTests.swift`
- Modify: `Tests/AISpendUITests/AppModelTests.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: the Task 1 complete result with an informational unavailable
  account-scope attempt and a successful personal-scope attempt.
- Produces: fresh provider state, a non-partial combined summary, normal budget
  projections, and user-facing setup text that describes personal scope as the
  common case.

- [ ] **Step 1: Replace the coordinator partial-fallback fixture with a failing success-state assertion**

Rename `testPartialProviderCoverageKeepsFreshRecordsAndMarksSummaryPartial` to
`testPersonalScopeFallbackKeepsFreshRecordsWithoutMarkingSummaryPartial`.
Construct:

```swift
ProviderFetchResult(
  provider: .fireworks,
  records: [freshRecord],
  attempts: [
    SourceAttempt(
      strategyID: "fireworks-account-costs",
      outcome: .unavailable(
        reason: "Account-wide Fireworks permission unavailable; using personal spend."
      )
    ),
    SourceAttempt(
      strategyID: "fireworks-self-costs",
      outcome: .succeeded(recordCount: 1)
    ),
  ],
  refreshedSourceIDs: [freshRecord.sourceID],
  fetchedAt: fetchedAt,
  coverage: .complete,
  sourceAuthority: .allProviderSources
)
```

Assert:

```swift
XCTAssertEqual(snapshot.summary.total, Money(4))
XCTAssertFalse(snapshot.summary.isPartial)
XCTAssertEqual(snapshot.providerStates[.fireworks]?.refreshStatus, .success)
XCTAssertNil(snapshot.providerStates[.fireworks]?.lastFailureMessage)
XCTAssertEqual(snapshot.providerAvailability[.fireworks], .available)
XCTAssertEqual(snapshot.attempts[.fireworks]?.count, 2)
```

- [ ] **Step 2: Run the coordinator test**

```bash
rtk swift test --filter RefreshCoordinatorTests/testPersonalScopeFallbackKeepsFreshRecordsWithoutMarkingSummaryPartial
```

Expected: PASS once Task 1's result contract is represented; this locks the
coordinator behavior that `.unavailable` is informational when another source
refreshed.

- [ ] **Step 3: Add an AppModel regression for normal freshness**

Add a snapshot fixture with Fireworks:

- `refreshStatus: .success`;
- a recent `lastSuccessfulAt`;
- personal-scope informational and successful attempts;
- a non-partial summary.

Assert:

```swift
let row = try XCTUnwrap(model.providerRows.first { $0.id == .fireworks })
guard case .fresh = row.status.freshness else {
  return XCTFail("Expected fresh Fireworks personal spend")
}
XCTAssertFalse(model.needsAttention)
```

- [ ] **Step 4: Run the AppModel test**

```bash
rtk swift test --filter AppModelTests
```

Expected: PASS and no regression to genuine `.partial` presentation.

- [ ] **Step 5: Update README scope language**

Replace language saying personal fallback creates a visible partial state with:

```markdown
AI Spend treats authenticated-user Fireworks costs as normal fresh coverage,
which is the common personal-use setup. Provider diagnostics identify the
source as personal spend. If another discovered account cannot be queried at
either scope, Fireworks is marked partial; if every account fails, the refresh
is marked failed.
```

Keep the existing standard-key, Fire Pass, Node.js, billing-delay, Azure, and
Claude Code deduplication guidance.

- [ ] **Step 6: Run integration and full verification**

```bash
rtk swift test --filter RefreshCoordinatorTests
rtk swift test --filter AppModelTests
rtk swift test
rtk swift format lint --recursive Sources Tests Package.swift
rtk bash Scripts/package_app.sh
rtk bash Tests/Smoke/app_bundle_test.sh
rtk git diff --check origin/master...
```

Expected: all tests and checks pass, packaging succeeds, the runtime self-check
and strict code-signature validation pass, and the diff contains only the
personal-scope behavior/spec changes.

- [ ] **Step 7: Commit Task 2**

```bash
rtk git add Tests/AISpendCoreTests/RefreshCoordinatorTests.swift Tests/AISpendUITests/AppModelTests.swift README.md
rtk git commit -m "docs: explain Fireworks personal spend scope"
```

