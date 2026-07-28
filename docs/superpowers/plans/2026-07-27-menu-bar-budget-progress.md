# Menu Bar Budget Progress Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the static dollar-sign menu bar icon with a circular indicator of current monthly spend against the lowest enabled budget while preserving existing health-state fallbacks.

**Architecture:** `AppModel` derives a small immutable `MenuBarBudgetProgress` value from the current snapshot and the first limit-sorted budget evaluation. A focused SwiftUI view renders that value as a monochrome ring around a dollar sign, while `AISpendBarApp` retains the existing SF Symbols whenever progress is unavailable.

**Tech Stack:** Swift 6, SwiftUI, Observation, XCTest, Swift Package Manager, macOS 14+

## Global Constraints

- Progress is current calendar-month spend divided by the lowest enabled budget.
- Clamp only the rendered arc to zero through one; retain the true percentage for accessibility.
- Preserve the existing spend title.
- Preserve the question-mark fallback for unavailable data and the warning fallback when all data is stale.
- With partial but usable data, show the ring and retain the existing exclamation mark in the title.
- With no enabled budget, retain the existing dollar-sign status icon.
- Keep the indicator monochrome and do not change pacing, alerts, budget ordering, or popover rows.
- Do not rename the current branch.

---

## File Structure

- Create `Sources/AISpendUI/Menu/MenuBarBudgetProgressIcon.swift`: owns the progress presentation value and the compact SwiftUI ring renderer.
- Modify `Sources/AISpendUI/AppModel.swift`: derives menu bar progress from current spend, budget evaluations, and health state.
- Modify `Sources/AISpendBar/AISpendBarApp.swift`: selects the progress icon or existing SF Symbol fallback in the `MenuBarExtra` label.
- Modify `Tests/AISpendUITests/AppModelTests.swift`: verifies budget selection, arithmetic, clamping, health fallbacks, and partial-data behavior.

### Task 1: Integrate the Application Source Baseline

**Files:**
- Merge from: local `master`
- Preserve from current branch: `README.md`, `.github/workflows/app-bundle.yml`, `docs/superpowers/specs/2026-07-27-menu-bar-budget-progress-design.md`

**Interfaces:**
- Consumes: the complete AI Spend application history on local `master`
- Produces: a feature branch containing the Swift package, app sources, tests, CI workflow, current README, and approved feature spec

- [ ] **Step 1: Confirm both histories and a clean tracked worktree**

Run:

```bash
rtk git status --short --branch
rtk git rev-parse HEAD master origin/master
rtk git merge-base HEAD master
```

Expected: the current branch is `Asherlc/menu-bar-budget-progress`; only `.superpowers/` may be untracked; `HEAD` descends from `origin/master`; and `HEAD` and local `master` share the initial repository commit.

- [ ] **Step 2: Merge the application history while favoring current documentation in conflicts**

Run:

```bash
rtk git merge --no-ff -X ours master -m "merge: integrate application source"
```

Expected: the merge brings in `Package.swift`, `Sources/`, `Tests/`, and `Scripts/`; the current README and CI workflow remain present.

- [ ] **Step 3: Verify the integrated baseline before feature work**

Run:

```bash
rtk git status --short --branch
rtk git ls-files Package.swift Sources Tests Scripts .github/workflows/app-bundle.yml README.md
rtk swift test
```

Expected: no tracked conflicts or modifications remain, all application paths are tracked, and the pre-feature Swift test suite passes.

### Task 2: Derive Budget Progress in `AppModel`

**Files:**
- Create: `Sources/AISpendUI/Menu/MenuBarBudgetProgressIcon.swift`
- Modify: `Sources/AISpendUI/AppModel.swift`
- Test: `Tests/AISpendUITests/AppModelTests.swift`

**Interfaces:**
- Consumes: `AppModel.snapshot`, `AppModel.availability`, and the limit-sorted `AppModel.budgetEvaluations`
- Produces: `public struct MenuBarBudgetProgress: Equatable, Sendable` with `fraction: Double`, `percentage: Decimal`, `limit: Money`, and `accessibilityLabel: String`; plus `AppModel.menuBarBudgetProgress: MenuBarBudgetProgress?`

- [ ] **Step 1: Extend the snapshot test helper to express partial and stale states**

Add `isPartial` and `allDataIsStale` parameters and pass them into both the summary/pacing setup and `RefreshSnapshot`:

```swift
private static func snapshot(
  total: Decimal,
  providers: [ProviderSpendSummary],
  budgets: [BudgetDefinition] = [],
  providerStates: [ProviderID: StoredProviderState] = [:],
  attempts: [ProviderID: [SourceAttempt]] = [:],
  dataAvailability: CurrentMonthDataAvailability? = nil,
  providerAvailability: [ProviderID: CurrentMonthDataAvailability] = [:],
  monthWindow: MonthWindow? = nil,
  refreshedAt: Date = Date(timeIntervalSince1970: 100),
  evaluatedAt: Date? = nil,
  isPartial: Bool = false,
  allDataIsStale: Bool = false
) -> RefreshSnapshot {
  let actual = providers.reduce(Money.zero) { $0 + $1.actual }
  let estimated = providers.reduce(Money.zero) { $0 + $1.estimated }
  let start = Date(timeIntervalSince1970: 0)
  let end = start.addingTimeInterval(30 * 24 * 60 * 60)
  let now = start.addingTimeInterval(10 * 24 * 60 * 60)
  let window = monthWindow ?? MonthWindow(start: start, end: end)
  return RefreshSnapshot(
    summary: MonthlySummary(
      total: Money(total),
      actual: actual,
      estimated: estimated,
      providers: providers,
      isPartial: isPartial
    ),
    pacing: PacingEngine().evaluate(
      spend: Money(total),
      budgets: budgets,
      now: now,
      window: window,
      hasAnyData: !providers.isEmpty,
      allDataIsStale: allDataIsStale,
      isPartial: isPartial
    ),
    attempts: attempts,
    allDataIsStale: allDataIsStale,
    refreshedAt: refreshedAt,
    evaluatedAt: evaluatedAt,
    monthWindow: window,
    providerStates: providerStates,
    dataAvailability: dataAvailability,
    providerAvailability: providerAvailability
  )
}
```

- [ ] **Step 2: Write failing tests for selection, arithmetic, clamping, and accessibility**

Add focused tests to `AppModelTests`:

```swift
func testMenuBarProgressUsesCurrentSpendAgainstLowestEnabledBudget() {
  let snapshot = Self.snapshot(
    total: 20,
    providers: [
      ProviderSpendSummary(
        id: .openAI,
        actual: Money(20),
        estimated: .zero,
        models: []
      )
    ],
    budgets: [
      BudgetDefinition(
        id: UUID(),
        limit: Money(25),
        isEnabled: false,
        createdAt: .distantPast
      ),
      BudgetDefinition(
        id: UUID(),
        limit: Money(100),
        isEnabled: true,
        createdAt: .distantPast
      ),
      BudgetDefinition(
        id: UUID(),
        limit: Money(50),
        isEnabled: true,
        createdAt: .distantPast
      ),
    ]
  )
  let model = AppModel(snapshot: snapshot, refresh: { _ in snapshot })

  guard let progress = model.menuBarBudgetProgress else {
    return XCTFail("Expected budget progress")
  }
  XCTAssertEqual(progress.limit, Money(50))
  XCTAssertEqual(progress.fraction, 0.4, accuracy: 0.0001)
  XCTAssertEqual(progress.percentage, 40)
  XCTAssertEqual(
    progress.accessibilityLabel,
    "40% of $50.00 budget used"
  )
}

func testMenuBarProgressClampsRenderedArcButRetainsOverspendPercentage() {
  let snapshot = Self.snapshot(
    total: 75,
    providers: [
      ProviderSpendSummary(
        id: .openAI,
        actual: Money(75),
        estimated: .zero,
        models: []
      )
    ],
    budgets: [
      BudgetDefinition(
        id: UUID(),
        limit: Money(50),
        isEnabled: true,
        createdAt: .distantPast
      )
    ]
  )
  let model = AppModel(snapshot: snapshot, refresh: { _ in snapshot })

  XCTAssertEqual(model.menuBarBudgetProgress?.fraction, 1)
  XCTAssertEqual(model.menuBarBudgetProgress?.percentage, 150)
  XCTAssertEqual(
    model.menuBarBudgetProgress?.accessibilityLabel,
    "150% of $50.00 budget used"
  )
}
```

- [ ] **Step 3: Write failing tests for fallback and partial-data behavior**

Add these tests to `AppModelTests`:

```swift
func testMenuBarProgressIsAbsentWithoutAnEnabledBudget() {
  let model = AppModel(
    snapshot: Self.initialSnapshot,
    refresh: { _ in Self.initialSnapshot }
  )

  XCTAssertNil(model.menuBarBudgetProgress)
}

func testMenuBarProgressIsAbsentWhenCurrentMonthDataIsUnavailable() {
  let snapshot = Self.snapshot(
    total: 20,
    providers: [],
    budgets: [
      BudgetDefinition(
        id: UUID(),
        limit: Money(50),
        isEnabled: true,
        createdAt: .distantPast
      )
    ],
    dataAvailability: .unavailable
  )
  let model = AppModel(snapshot: snapshot, refresh: { _ in snapshot })

  XCTAssertNil(model.menuBarBudgetProgress)
}

func testMenuBarProgressIsAbsentWhenAllDataIsStale() {
  let snapshot = Self.snapshot(
    total: 20,
    providers: [
      ProviderSpendSummary(
        id: .openAI,
        actual: Money(20),
        estimated: .zero,
        models: []
      )
    ],
    budgets: [
      BudgetDefinition(
        id: UUID(),
        limit: Money(50),
        isEnabled: true,
        createdAt: .distantPast
      )
    ],
    allDataIsStale: true
  )
  let model = AppModel(snapshot: snapshot, refresh: { _ in snapshot })

  XCTAssertNil(model.menuBarBudgetProgress)
}

func testMenuBarProgressRemainsAvailableForPartialCurrentData() {
  let snapshot = Self.snapshot(
    total: 20,
    providers: [
      ProviderSpendSummary(
        id: .openAI,
        actual: Money(20),
        estimated: .zero,
        models: []
      )
    ],
    budgets: [
      BudgetDefinition(
        id: UUID(),
        limit: Money(50),
        isEnabled: true,
        createdAt: .distantPast
      )
    ],
    isPartial: true
  )
  let model = AppModel(snapshot: snapshot, refresh: { _ in snapshot })

  guard let progress = model.menuBarBudgetProgress else {
    return XCTFail("Expected budget progress")
  }
  XCTAssertEqual(progress.fraction, 0.4, accuracy: 0.0001)
  XCTAssertTrue(model.needsAttention)
}
```

- [ ] **Step 4: Run the focused tests and verify the red state**

Run:

```bash
rtk swift test --filter AppModelTests
```

Expected: compilation fails because `AppModel` has no `menuBarBudgetProgress` property.

- [ ] **Step 5: Add the minimal progress presentation value**

Create `Sources/AISpendUI/Menu/MenuBarBudgetProgressIcon.swift` with the value type first:

```swift
import AISpendCore
import Foundation
import SwiftUI

public struct MenuBarBudgetProgress: Equatable, Sendable {
  public let fraction: Double
  public let percentage: Decimal
  public let limit: Money

  public var accessibilityLabel: String {
    let percentageText = NSDecimalNumber(decimal: percentage).stringValue
    return "\(percentageText)% of \(SpendFormatting.currency(limit)) budget used"
  }

  public init(
    fraction: Double,
    percentage: Decimal,
    limit: Money
  ) {
    self.fraction = fraction
    self.percentage = percentage
    self.limit = limit
  }
}
```

- [ ] **Step 6: Add the minimal `AppModel` derivation**

Add this computed property beside the existing status-title and symbol properties:

```swift
public var menuBarBudgetProgress: MenuBarBudgetProgress? {
  guard availability != .unavailable,
    !snapshot.allDataIsStale,
    let budget = budgetEvaluations.first,
    budget.limit.amount > 0
  else {
    return nil
  }
  let ratio = snapshot.summary.total.amount / budget.limit.amount
  let clampedRatio = min(max(ratio, 0), 1)
  return MenuBarBudgetProgress(
    fraction: NSDecimalNumber(decimal: clampedRatio).doubleValue,
    percentage: ratio * 100,
    limit: budget.limit
  )
}
```

- [ ] **Step 7: Run focused and module tests and verify green**

Run:

```bash
rtk swift test --filter AppModelTests
rtk swift test --filter AISpendUITests
```

Expected: all `AppModelTests` and all `AISpendUITests` pass.

- [ ] **Step 8: Commit the tested presentation behavior**

Run:

```bash
rtk git add Sources/AISpendUI/AppModel.swift Sources/AISpendUI/Menu/MenuBarBudgetProgressIcon.swift Tests/AISpendUITests/AppModelTests.swift
rtk git commit -m "feat: derive menu bar budget progress"
```

### Task 3: Render and Wire the Menu Bar Progress Ring

**Files:**
- Modify: `Sources/AISpendUI/Menu/MenuBarBudgetProgressIcon.swift`
- Modify: `Sources/AISpendBar/AISpendBarApp.swift`
- Test: `Tests/AISpendUITests/AppModelTests.swift`

**Interfaces:**
- Consumes: `MenuBarBudgetProgress` and `AppModel.menuBarBudgetProgress`
- Produces: `public struct MenuBarBudgetProgressIcon: View` and a `MenuBarExtra` label that chooses the ring or existing `statusSymbol`

- [ ] **Step 1: Add a compile-time usage test for the public icon view**

Add this test to `AppModelTests`:

```swift
func testMenuBarProgressIconCanRenderDerivedProgress() {
  let progress = MenuBarBudgetProgress(
    fraction: 0.4,
    percentage: 40,
    limit: Money(50)
  )

  _ = MenuBarBudgetProgressIcon(progress: progress).body
}
```

- [ ] **Step 2: Run the focused test and verify the red state**

Run:

```bash
rtk swift test --filter AppModelTests/testMenuBarProgressIconCanRenderDerivedProgress
```

Expected: compilation fails because `MenuBarBudgetProgressIcon` is not defined.

- [ ] **Step 3: Implement the compact monochrome progress icon**

Append this view to `MenuBarBudgetProgressIcon.swift`:

```swift
public struct MenuBarBudgetProgressIcon: View {
  private let progress: MenuBarBudgetProgress

  public init(progress: MenuBarBudgetProgress) {
    self.progress = progress
  }

  public var body: some View {
    ZStack {
      Circle()
        .stroke(lineWidth: 1.5)
        .opacity(0.25)
      Circle()
        .trim(from: 0, to: progress.fraction)
        .stroke(
          style: StrokeStyle(
            lineWidth: 2,
            lineCap: .round
          )
        )
        .rotationEffect(.degrees(-90))
      Text("$")
        .font(.system(size: 10, weight: .semibold, design: .rounded))
    }
    .frame(width: 18, height: 18)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(progress.accessibilityLabel)
  }
}
```

- [ ] **Step 4: Run the focused test and verify green**

Run:

```bash
rtk swift test --filter AppModelTests/testMenuBarProgressIconCanRenderDerivedProgress
```

Expected: the icon usage test passes.

- [ ] **Step 5: Select the progress view in the `MenuBarExtra` label**

Replace the existing `Label(model.statusTitle, systemImage: model.statusSymbol)` with:

```swift
Label {
  Text(model.statusTitle)
} icon: {
  if let progress = model.menuBarBudgetProgress {
    MenuBarBudgetProgressIcon(progress: progress)
  } else {
    Image(systemName: model.statusSymbol)
  }
}
```

- [ ] **Step 6: Run all automated verification**

Run:

```bash
rtk swift test
rtk swift format lint --recursive Sources Tests Package.swift
rtk swift build
```

Expected: all tests pass, formatting lint reports no violations, and the app builds successfully.

- [ ] **Step 7: Review the final branch diff**

Run:

```bash
rtk git diff --check
rtk git diff origin/master... --stat
rtk git status --short
```

Expected: no whitespace errors; the branch contains the integrated application plus the focused progress feature; only `.superpowers/` may remain untracked.

- [ ] **Step 8: Commit the rendered progress indicator**

Run:

```bash
rtk git add Sources/AISpendUI/Menu/MenuBarBudgetProgressIcon.swift Sources/AISpendBar/AISpendBarApp.swift Tests/AISpendUITests/AppModelTests.swift
rtk git commit -m "feat: show budget progress in menu bar"
```
