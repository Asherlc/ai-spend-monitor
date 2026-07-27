# AI Spend Menu Bar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native macOS menu bar app that aggregates current-calendar-month metered AI spend from Cursor, Claude, and Codex/OpenAI, shows provider/model detail, evaluates multiple combined budgets, and sends paced alerts.

**Architecture:** A Swift package separates domain and persistence (`AISpendCore`), provider-specific discovery/fetch/parsing (`AISpendProviders`), reusable SwiftUI views (`AISpendUI`), and the thin menu-bar executable (`AISpendBar`). Provider adapters emit normalized daily spend records; a reconciler gives actual billing precedence over estimates; a refresh coordinator persists records, creates the monthly summary, evaluates budgets, and invokes a throttled notification engine.

**Tech Stack:** Swift 6.3, SwiftUI, AppKit, SwiftData, Security, UserNotifications, OSLog, XCTest, Swift Package Manager, macOS 14+

## Global Constraints

- Minimum deployment target is macOS 14 Sonoma.
- The app is menu-bar-only and has no Dock icon during normal operation.
- All currency is decimal USD; do not aggregate currency with `Double`.
- The current month uses the Mac's current calendar and timezone.
- Fixed subscription and seat fees never contribute to spend.
- Actual billed records replace overlapping estimates; ambiguous estimates are excluded rather than double-counted.
- No provider credential-entry UI is permitted.
- Provider credentials may only be reused from allowlisted environment, CLI, application, Keychain, or browser-session locations and must never be persisted or logged by this app.
- Disabled providers perform no credential discovery, file reads, browser reads, subprocesses, or network requests.
- Normal refresh cadence is 15 minutes; data becomes stale after 30 minutes.
- An off-pace budget alerts immediately on transition, then at most once per local calendar day.

---

## File Map

### Package and application shell

- `Package.swift` — products, targets, resources, deployment version, strict concurrency.
- `Sources/AISpendBar/AISpendBarApp.swift` — `@main` app, `MenuBarExtra`, settings scene, dependency composition.
- `Sources/AISpendBar/AISpendBarBootstrap.swift` — temporary executable entry point, deleted when the real app is added.
- `Sources/AISpendUI/AppModel.swift` — main-actor application state and refresh triggers.
- `Sources/AISpendBar/Resources/Info.plist` — menu-bar-only application metadata.
- `Scripts/package_app.sh` — creates `AISpendBar.app` from the release executable.

### Core domain and persistence

- `Sources/AISpendCore/Domain/Money.swift` — decimal USD value type.
- `Sources/AISpendCore/Domain/Provider.swift` — provider IDs, descriptors, source states.
- `Sources/AISpendCore/Domain/SpendRecord.swift` — normalized actual/estimated record.
- `Sources/AISpendCore/Domain/Budget.swift` — budgets, pacing states, alert metadata.
- `Sources/AISpendCore/Domain/MonthlySummary.swift` — headline, provider, and model summaries.
- `Sources/AISpendCore/Providers/ProviderAdapter.swift` — common adapter, fetch result, and diagnostic interfaces.
- `Sources/AISpendCore/Calendar/MonthWindow.swift` — local-calendar interval calculation.
- `Sources/AISpendCore/Pacing/PacingEngine.swift` — projection and budget evaluation.
- `Sources/AISpendCore/Ledger/SpendReconciler.swift` — deduplication and actual-over-estimate precedence.
- `Sources/AISpendCore/Ledger/SpendAggregator.swift` — monthly/provider/model aggregation.
- `Sources/AISpendCore/Persistence/Models.swift` — SwiftData entities.
- `Sources/AISpendCore/Persistence/LedgerRepository.swift` — persistence protocol and SwiftData implementation.
- `Sources/AISpendCore/Refresh/RefreshCoordinator.swift` — concurrent adapter orchestration and partial failure behavior.
- `Sources/AISpendCore/Alerts/BudgetAlertEngine.swift` — immediate/daily alert decisions.
- `Sources/AISpendCore/Clock.swift` — injectable wall clock.

### Provider infrastructure and adapters

- `Sources/AISpendProviders/Hosting/CredentialHost.swift` — allowlisted environment/file/Keychain credential reads.
- `Sources/AISpendProviders/Hosting/CursorStateReader.swift` — read-only Cursor application-state discovery.
- `Sources/AISpendProviders/Hosting/HTTPClient.swift` — allowlisted provider HTTP client.
- `Sources/AISpendProviders/Hosting/Redactor.swift` — diagnostic redaction.
- `Sources/AISpendProviders/Estimation/PriceCatalog.swift` — versioned model price lookup.
- `Sources/AISpendProviders/Estimation/LocalUsage.swift` — common token observation.
- `Sources/AISpendProviders/Estimation/ClaudeLogScanner.swift` — Claude Code JSONL scanner.
- `Sources/AISpendProviders/Estimation/CodexLogScanner.swift` — Codex JSONL scanner.
- `Sources/AISpendProviders/Providers/Claude/ClaudeAdapter.swift` — strategy ordering and normalization.
- `Sources/AISpendProviders/Providers/Claude/ClaudeCostClient.swift` — Anthropic cost report.
- `Sources/AISpendProviders/Providers/OpenAI/OpenAIAdapter.swift` — strategy ordering and normalization.
- `Sources/AISpendProviders/Providers/OpenAI/OpenAICostClient.swift` — OpenAI organization costs.
- `Sources/AISpendProviders/Providers/Cursor/CursorAdapter.swift` — Cursor state/admin strategy ordering.
- `Sources/AISpendProviders/Providers/Cursor/CursorUsageClient.swift` — Cursor filtered usage events.
- `Sources/AISpendProviders/Resources/model-prices.json` — checked-in versioned USD token prices.

### UI

- `Sources/AISpendUI/SpendFormatting.swift` — amount, percentage, date, and freshness formatting.
- `Sources/AISpendUI/Menu/SpendPopoverView.swift` — headline, budgets, providers, refresh/settings controls.
- `Sources/AISpendUI/Menu/BudgetPaceRow.swift` — one combined budget row.
- `Sources/AISpendUI/Menu/ProviderRow.swift` — provider summary row.
- `Sources/AISpendUI/Menu/ProviderDetailView.swift` — provider/model drill-down and daily sparkline.
- `Sources/AISpendUI/Settings/SettingsView.swift` — providers, budgets, privacy tabs.
- `Sources/AISpendUI/Settings/ProviderSettingsView.swift` — provider toggles and diagnostics.
- `Sources/AISpendUI/Settings/BudgetSettingsView.swift` — add/edit/enable/remove budgets.
- `Sources/AISpendUI/Settings/PrivacySettingsView.swift` — browser discovery and permission explanations.
- `Sources/AISpendUI/Diagnostics/ProviderDiagnosticsView.swift` — redacted source attempts.

### Tests and fixtures

- `Tests/AISpendCoreTests/` — money, month, pacing, reconciliation, aggregation, persistence, refresh, alerts.
- `Tests/AISpendProvidersTests/` — discovery, redaction, scanners, API parsing, adapter fallback.
- `Tests/AISpendUITests/` — formatting and deterministic view-model state.
- `Tests/AISpendProvidersTests/Fixtures/` — sanitized provider and local-log JSON fixtures.

---

### Task 1: Scaffold the Package and Core Domain

**Files:**
- Create: `Package.swift`
- Create: `Sources/AISpendProviders/AISpendProviders.swift`
- Create: `Sources/AISpendProviders/Resources/README.txt`
- Create: `Sources/AISpendUI/AISpendUI.swift`
- Create: `Sources/AISpendBar/AISpendBarBootstrap.swift`
- Create: `Sources/AISpendBar/Resources/README.txt`
- Create: `Sources/AISpendCore/Domain/Money.swift`
- Create: `Sources/AISpendCore/Domain/Provider.swift`
- Create: `Sources/AISpendCore/Domain/SpendRecord.swift`
- Create: `Sources/AISpendCore/Domain/Budget.swift`
- Create: `Sources/AISpendCore/Domain/MonthlySummary.swift`
- Create: `Sources/AISpendCore/Clock.swift`
- Create: `Tests/AISpendCoreTests/MoneyTests.swift`
- Create: `Tests/AISpendCoreTests/DomainTests.swift`
- Create: `Tests/AISpendProvidersTests/AISpendProvidersBootstrapTests.swift`
- Create: `Tests/AISpendProvidersTests/Fixtures/README.txt`
- Create: `Tests/AISpendUITests/AISpendUIBootstrapTests.swift`

**Interfaces:**
- Produces: `Money`, `ProviderID`, `SpendQuality`, `SpendRecord`, `BudgetDefinition`, `BudgetPacingState`, `MonthlySummary`, `Clock`.
- Consumes: Foundation only.

- [ ] **Step 1: Write failing money and domain tests**

```swift
import XCTest
@testable import AISpendCore

final class MoneyTests: XCTestCase {
    func testDecimalAdditionDoesNotUseBinaryFloatingPoint() {
        XCTAssertEqual(Money(Decimal(string: "0.10")!) + Money(Decimal(string: "0.20")!),
                       Money(Decimal(string: "0.30")!))
    }

    func testRejectsNonUSDAtDecodeBoundary() throws {
        let data = #"{"amount":"1.25","currency":"EUR"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(Money.self, from: data))
    }
}

final class DomainTests: XCTestCase {
    func testEveryFirstVersionProviderHasDescriptor() {
        XCTAssertEqual(Set(ProviderID.allCases), [.cursor, .claude, .openAI])
        XCTAssertEqual(ProviderDescriptor.builtIns.map(\.id), ProviderID.allCases)
    }

    func testSpendRecordRequiresHalfOpenPositiveInterval() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertThrowsError(try SpendRecord(
            id: "bad", provider: .claude, accountFingerprint: "acct",
            model: "claude", intervalStart: now, intervalEnd: now,
            amount: Money(1), quality: .estimated, sourceID: "log",
            observationID: "event", fetchedAt: now, estimate: nil))
    }
}
```

- [ ] **Step 2: Run the tests and verify the package is not yet defined**

Run: `rtk swift test --filter 'MoneyTests|DomainTests'`

Expected: FAIL because `Package.swift` and `AISpendCore` do not exist.

- [ ] **Step 3: Add the package manifest and core types**

Use this target graph in `Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AISpendBar",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "AISpendBar", targets: ["AISpendBar"])],
    targets: [
        .target(name: "AISpendCore"),
        .target(name: "AISpendProviders", dependencies: ["AISpendCore"],
                resources: [.process("Resources")],
                linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "AISpendUI", dependencies: ["AISpendCore", "AISpendProviders"]),
        .executableTarget(name: "AISpendBar",
                          dependencies: ["AISpendCore", "AISpendProviders", "AISpendUI"],
                          resources: [.process("Resources")]),
        .testTarget(name: "AISpendCoreTests", dependencies: ["AISpendCore"]),
        .testTarget(name: "AISpendProvidersTests",
                    dependencies: ["AISpendCore", "AISpendProviders"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "AISpendUITests",
                    dependencies: ["AISpendCore", "AISpendProviders", "AISpendUI"]),
    ],
    swiftLanguageModes: [.v6]
)
```

Add minimal bootstrap declarations so every manifest target exists from the first commit:

```swift
// Sources/AISpendProviders/AISpendProviders.swift
public enum AISpendProvidersModule {}

// Sources/AISpendUI/AISpendUI.swift
public enum AISpendUIModule {}

// Sources/AISpendBar/AISpendBarBootstrap.swift
@main
enum AISpendBarBootstrap {
    static func main() {}
}
```

Add one empty XCTest case to each bootstrap test target. Add resource `README.txt` files explaining that the app metadata, price catalog, and sanitized fixtures are added by later tasks.

```swift
import XCTest

final class AISpendProvidersBootstrapTests: XCTestCase {
    func testBootstrap() {
        XCTAssertTrue(true)
    }
}

final class AISpendUIBootstrapTests: XCTestCase {
    func testBootstrap() {
        XCTAssertTrue(true)
    }
}
```

Implement these declarations:

```swift
public struct Money: Codable, Hashable, Comparable, Sendable {
    public let amount: Decimal
    public let currency: String
    public init(_ amount: Decimal, currency: String = "USD")
    public static let zero: Money
    public static func + (lhs: Money, rhs: Money) -> Money
    public static func - (lhs: Money, rhs: Money) -> Money
    public static func * (lhs: Money, rhs: Decimal) -> Money
}

public enum ProviderID: String, Codable, CaseIterable, Sendable {
    case cursor
    case claude
    case openAI = "openai"
}

public enum SpendQuality: String, Codable, Sendable {
    case actual
    case estimated
}

public struct EstimateMetadata: Codable, Hashable, Sendable {
    public let inputTokens: Int
    public let cachedInputTokens: Int
    public let outputTokens: Int
    public let catalogVersion: String
}

public struct SpendRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let provider: ProviderID
    public let accountFingerprint: String
    public let model: String
    public let intervalStart: Date
    public let intervalEnd: Date
    public let amount: Money
    public let quality: SpendQuality
    public let sourceID: String
    public let observationID: String
    public let fetchedAt: Date
    public let estimate: EstimateMetadata?
}

public struct BudgetDefinition: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var limit: Money
    public var isEnabled: Bool
    public let createdAt: Date
}

public enum BudgetPacingState: String, Codable, Sendable {
    case collecting
    case onPace
    case offPace
    case unknown
}

public protocol Clock: Sendable {
    var now: Date { get }
}
```

Make `SpendRecord.init` throwing, reject `intervalEnd <= intervalStart`, negative money, empty source IDs, and non-USD values. `Money` encodes amount as a base-10 string and throws on any currency other than `USD`.

- [ ] **Step 4: Run the focused tests**

Run: `rtk swift test --filter 'MoneyTests|DomainTests'`

Expected: PASS.

- [ ] **Step 5: Run formatting and commit**

Run: `rtk swift format lint --recursive Sources Tests Package.swift`

Expected: no formatter diagnostics.

Commit:

```bash
rtk git add Package.swift Sources/AISpendCore Tests/AISpendCoreTests
rtk git commit -m "feat: add spend domain model"
```

---

### Task 2: Implement Calendar Months and Multi-Budget Pacing

**Files:**
- Create: `Sources/AISpendCore/Calendar/MonthWindow.swift`
- Create: `Sources/AISpendCore/Pacing/PacingEngine.swift`
- Create: `Tests/AISpendCoreTests/MonthWindowTests.swift`
- Create: `Tests/AISpendCoreTests/PacingEngineTests.swift`

**Interfaces:**
- Consumes: `Money`, `BudgetDefinition`, `BudgetPacingState`.
- Produces: `MonthWindow.current(containing:calendar:)`, `PacingEngine.evaluate`.

- [ ] **Step 1: Write failing calendar and pacing tests**

```swift
import XCTest
@testable import AISpendCore

final class MonthWindowTests: XCTestCase {
    func testLeapFebruaryUsesLocalCalendarBoundaries() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = ISO8601DateFormatter().date(from: "2024-02-15T20:00:00Z")!
        let window = try MonthWindow.current(containing: now, calendar: calendar)
        XCTAssertEqual(calendar.component(.day, from: window.start), 1)
        XCTAssertEqual(calendar.component(.month, from: window.end), 3)
        XCTAssertEqual(window.duration,
                       window.end.timeIntervalSince(window.start),
                       accuracy: 0.001)
    }
}

final class PacingEngineTests: XCTestCase {
    func testEvaluatesMultipleBudgetsIndependently() throws {
        let start = Date(timeIntervalSince1970: 0)
        let window = MonthWindow(start: start, end: start.addingTimeInterval(100))
        let result = PacingEngine().evaluate(
            spend: Money(400), budgets: [
                BudgetDefinition(id: UUID(), limit: Money(500), isEnabled: true, createdAt: start),
                BudgetDefinition(id: UUID(), limit: Money(1_500), isEnabled: true, createdAt: start),
            ],
            now: start.addingTimeInterval(50), window: window,
            hasAnyData: true, allDataIsStale: false)
        XCTAssertEqual(result.projection, Money(800))
        XCTAssertEqual(result.budgets.map(\.state), [.offPace, .onPace])
    }

    func testCollectsForFirstSixHours() {
        let start = Date(timeIntervalSince1970: 0)
        let window = MonthWindow(start: start, end: start.addingTimeInterval(2_592_000))
        let result = PacingEngine().evaluate(
            spend: Money(5), budgets: [], now: start.addingTimeInterval(60),
            window: window, hasAnyData: true, allDataIsStale: false)
        XCTAssertNil(result.projection)
        XCTAssertTrue(result.isCollecting)
    }
}
```

- [ ] **Step 2: Verify the tests fail**

Run: `rtk swift test --filter 'MonthWindowTests|PacingEngineTests'`

Expected: FAIL because `MonthWindow` and `PacingEngine` are undefined.

- [ ] **Step 3: Implement real-time month fraction and budget evaluation**

```swift
public struct MonthWindow: Hashable, Sendable {
    public let start: Date
    public let end: Date
    public var duration: TimeInterval { end.timeIntervalSince(start) }
    public static func current(containing date: Date, calendar: Calendar) throws -> MonthWindow
    public func contains(_ date: Date) -> Bool { date >= start && date < end }
}

public struct BudgetEvaluation: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let limit: Money
    public let state: BudgetPacingState
    public let projectedMargin: Money?
}

public struct PacingResult: Hashable, Sendable {
    public let projection: Money?
    public let isCollecting: Bool
    public let isPartial: Bool
    public let budgets: [BudgetEvaluation]
}

public struct PacingEngine: Sendable {
    public func evaluate(
        spend: Money,
        budgets: [BudgetDefinition],
        now: Date,
        window: MonthWindow,
        hasAnyData: Bool,
        allDataIsStale: Bool,
        isPartial: Bool = false
    ) -> PacingResult
}
```

Use elapsed real seconds divided by `MonthWindow.duration`. Return `unknown` budget states with no projection when `hasAnyData` is false. Return `collecting` for the first six elapsed hours. Sort enabled budgets by limit ascending.

- [ ] **Step 4: Run calendar and pacing tests**

Run: `rtk swift test --filter 'MonthWindowTests|PacingEngineTests'`

Expected: PASS, including leap-year and multi-budget cases.

- [ ] **Step 5: Commit**

```bash
rtk git add Sources/AISpendCore/Calendar Sources/AISpendCore/Pacing Tests/AISpendCoreTests
rtk git commit -m "feat: add monthly budget pacing"
```

---

### Task 3: Reconcile and Aggregate Spend

**Files:**
- Create: `Sources/AISpendCore/Ledger/SpendReconciler.swift`
- Create: `Sources/AISpendCore/Ledger/SpendAggregator.swift`
- Create: `Tests/AISpendCoreTests/SpendReconcilerTests.swift`
- Create: `Tests/AISpendCoreTests/SpendAggregatorTests.swift`

**Interfaces:**
- Consumes: `[SpendRecord]`, `MonthWindow`, enabled `Set<ProviderID>`.
- Produces: `ReconciliationResult`, `MonthlySummary`.

- [ ] **Step 1: Write failing precedence and aggregation tests**

Create fixtures with an actual `$10` Claude daily record, an overlapping estimated `$12` record, and a non-overlapping estimated `$3` record. Assert:

```swift
let result = SpendReconciler().reconcile([actual, overlappingEstimate, uncoveredEstimate])
XCTAssertEqual(result.included.map(\.id), [actual.id, uncoveredEstimate.id])
XCTAssertEqual(result.excludedEstimatedAmount, Money(12))
```

Also assert aggregation:

```swift
let summary = SpendAggregator().summarize(
    records: result.included,
    enabledProviders: [.claude],
    window: month,
    providerFreshness: [.claude: .fresh])
XCTAssertEqual(summary.total, Money(13))
XCTAssertEqual(summary.actual, Money(10))
XCTAssertEqual(summary.estimated, Money(3))
XCTAssertEqual(summary.providers.first?.models.map(\.model), ["claude-opus", "claude-sonnet"])
```

- [ ] **Step 2: Verify failure**

Run: `rtk swift test --filter 'SpendReconcilerTests|SpendAggregatorTests'`

Expected: FAIL because reconciliation and aggregation types do not exist.

- [ ] **Step 3: Implement deterministic reconciliation**

```swift
public struct ReconciliationResult: Sendable {
    public let included: [SpendRecord]
    public let excludedEstimatedAmount: Money
    public let excludedRecordIDs: Set<String>
}

public struct SpendReconciler: Sendable {
    public func reconcile(_ records: [SpendRecord]) -> ReconciliationResult
}
```

Group by provider, account fingerprint, and model. Remove duplicate observation IDs first. Within each group, exclude estimates whose intervals intersect actual coverage. Preserve estimates fully outside actual coverage. Sort included records by interval start, provider raw value, model, then ID so tests and persistence are deterministic.

- [ ] **Step 4: Implement monthly/provider/model aggregation**

```swift
public enum Freshness: Hashable, Sendable {
    case fresh
    case stale(age: TimeInterval)
    case unavailable(message: String)
}

public struct SpendAggregator: Sendable {
    public func summarize(
        records: [SpendRecord],
        enabledProviders: Set<ProviderID>,
        window: MonthWindow,
        providerFreshness: [ProviderID: Freshness]
    ) -> MonthlySummary
}
```

Clip records to the half-open month by inclusion of records whose source bucket belongs to the month. Aggregate actual and estimated separately, sort providers and models by descending amount with stable name tie-breakers, and mark the total partial when any enabled provider is stale or unavailable.

- [ ] **Step 5: Run tests and commit**

Run: `rtk swift test --filter 'SpendReconcilerTests|SpendAggregatorTests'`

Expected: PASS.

Commit:

```bash
rtk git add Sources/AISpendCore/Ledger Tests/AISpendCoreTests
rtk git commit -m "feat: reconcile and aggregate spend"
```

---

### Task 4: Persist Records, Provider State, Budgets, and Alert State

**Files:**
- Create: `Sources/AISpendCore/Persistence/Models.swift`
- Create: `Sources/AISpendCore/Persistence/LedgerRepository.swift`
- Create: `Tests/AISpendCoreTests/LedgerRepositoryTests.swift`

**Interfaces:**
- Consumes: normalized records, provider refresh state, budgets, alert state.
- Produces: `LedgerRepository` protocol and `SwiftDataLedgerRepository`.

- [ ] **Step 1: Write failing in-memory SwiftData tests**

Use `ModelConfiguration(isStoredInMemoryOnly: true)` and assert:

```swift
try await repository.replace(records: [record], provider: .claude,
                             sourceID: "anthropic.cost", interval: month)
XCTAssertEqual(try await repository.records(in: month), [record])

try await repository.replace(records: [replacement], provider: .claude,
                             sourceID: "anthropic.cost", interval: month)
XCTAssertEqual(try await repository.records(in: month), [replacement])
```

Add tests that duplicate budget limits throw `LedgerError.duplicateBudget`, disabling a provider retains records, and failed refresh state does not remove prior records.

- [ ] **Step 2: Verify failure**

Run: `rtk swift test --filter LedgerRepositoryTests`

Expected: FAIL because persistence models and repository are missing.

- [ ] **Step 3: Add SwiftData entities**

Define `@Model` entities `SpendRecordEntity`, `ProviderStateEntity`, `BudgetEntity`, and `BudgetAlertStateEntity`. Store decimal money as canonical base-10 strings, provider/quality/state enums as raw strings, dates as `Date`, and estimate metadata as encoded JSON data.

Define the repository boundary:

```swift
@MainActor
public protocol LedgerRepository: AnyObject {
    func records(in window: MonthWindow) throws -> [SpendRecord]
    func replace(records: [SpendRecord], provider: ProviderID,
                 sourceID: String, interval: MonthWindow) throws
    func providerStates() throws -> [ProviderID: StoredProviderState]
    func saveProviderState(_ state: StoredProviderState) throws
    func budgets() throws -> [BudgetDefinition]
    func addBudget(limit: Money, now: Date) throws -> BudgetDefinition
    func updateBudget(_ budget: BudgetDefinition) throws
    func removeBudget(id: UUID) throws
    func alertState(for budgetID: UUID) throws -> StoredBudgetAlertState
    func saveAlertState(_ state: StoredBudgetAlertState) throws
}
```

`replace` must be transaction-like: decode and validate every incoming record before deleting the old successful source interval, then save once.

- [ ] **Step 4: Run persistence tests**

Run: `rtk swift test --filter LedgerRepositoryTests`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
rtk git add Sources/AISpendCore/Persistence Tests/AISpendCoreTests/LedgerRepositoryTests.swift
rtk git commit -m "feat: persist spend and budgets"
```

---

### Task 5: Build Read-Only Source Hosts and Redacted Diagnostics

**Files:**
- Create: `Sources/AISpendCore/Providers/ProviderAdapter.swift`
- Create: `Sources/AISpendProviders/Hosting/CredentialHost.swift`
- Create: `Sources/AISpendProviders/Hosting/CursorStateReader.swift`
- Create: `Sources/AISpendProviders/Hosting/HTTPClient.swift`
- Create: `Sources/AISpendProviders/Hosting/Redactor.swift`
- Create: `Tests/AISpendProvidersTests/CredentialHostTests.swift`
- Create: `Tests/AISpendProvidersTests/CursorStateReaderTests.swift`
- Create: `Tests/AISpendProvidersTests/HTTPClientTests.swift`
- Create: `Tests/AISpendProvidersTests/RedactorTests.swift`
- Create: `Tests/AISpendProvidersTests/Fixtures/cursor-state.json`

**Interfaces:**
- Produces: `ProviderAdapter`, `ProviderFetchResult`, `CredentialHost`, `CursorStateReader`, `HTTPClient`, `Redactor`.
- Consumes: `AISpendCore`, Foundation, Security, SQLite3.

- [ ] **Step 1: Write failing security-boundary tests**

Assert that:

- file reads outside exact allowlisted paths throw `SourceHostError.pathNotAllowed`;
- HTTP requests outside `api.anthropic.com`, `api.openai.com`, and `api.cursor.com` throw `SourceHostError.domainNotAllowed`;
- Keychain lookup accepts only exact service/account pairs;
- a diagnostic containing `Authorization`, `Cookie`, email, JWT, and API-key shapes returns none of their original values;
- Cursor state fixture keys `cursorAuth/accessToken`, `cursorAuth/cachedEmail`, and team ID decode without logging the values.

Example redaction assertion:

```swift
let output = Redactor().redact(
    "Authorization: Bearer eyJhbGciOi secret@example.com sk-ant-admin01-secret")
XCTAssertFalse(output.contains("eyJhbGciOi"))
XCTAssertFalse(output.contains("secret@example.com"))
XCTAssertFalse(output.contains("sk-ant-admin01-secret"))
```

- [ ] **Step 2: Verify failure**

Run: `rtk swift test --filter 'CredentialHostTests|CursorStateReaderTests|HTTPClientTests|RedactorTests'`

Expected: FAIL because host APIs are missing.

- [ ] **Step 3: Define adapter and diagnostic contracts**

```swift
public struct SourceAttempt: Hashable, Sendable {
    public let strategyID: String
    public let outcome: Outcome
    public enum Outcome: Hashable, Sendable {
        case succeeded(recordCount: Int)
        case unavailable(reason: String)
        case failed(redactedMessage: String)
    }
}

public struct ProviderFetchResult: Sendable {
    public let provider: ProviderID
    public let records: [SpendRecord]
    public let attempts: [SourceAttempt]
    public let fetchedAt: Date
}

public protocol ProviderAdapter: Sendable {
    var provider: ProviderID { get }
    func fetch(window: MonthWindow) async throws -> ProviderFetchResult
}
```

- [ ] **Step 4: Implement allowlisted hosts**

`CredentialHost` checks, in order, process environment, exact known CLI credential files, and exact Keychain service/account pairs. It returns ephemeral `Secret` values whose `description` and `debugDescription` are always `<redacted>`.

Use these first-version allowlisted file roots:

- `~/.claude/.credentials.json`
- `~/.codex/auth.json`
- `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`

Resolve `~` once with `FileManager.homeDirectoryForCurrentUser`; reject symlink escape by comparing standardized, resolved paths.

`CursorStateReader` opens a read-only copy or a read-only SQLite connection and queries only the `ItemTable` keys required for auth/team discovery. It never writes Cursor state.

`HTTPClient` validates HTTPS and exact hostname before sending. It uses ephemeral `URLSessionConfiguration`, disables URL caching, strips credentials from errors, and enforces a 20-second request timeout.

- [ ] **Step 5: Run host tests and commit**

Run: `rtk swift test --filter 'CredentialHostTests|CursorStateReaderTests|HTTPClientTests|RedactorTests'`

Expected: PASS.

Commit:

```bash
rtk git add Sources/AISpendCore/Providers/ProviderAdapter.swift Sources/AISpendProviders/Hosting Tests/AISpendProvidersTests
rtk git commit -m "feat: add secure provider source hosts"
```

---

### Task 6: Estimate Claude Code and Codex Spend from Local Logs

**Files:**
- Create: `Sources/AISpendProviders/Estimation/PriceCatalog.swift`
- Create: `Sources/AISpendProviders/Estimation/LocalUsage.swift`
- Create: `Sources/AISpendProviders/Estimation/ClaudeLogScanner.swift`
- Create: `Sources/AISpendProviders/Estimation/CodexLogScanner.swift`
- Create: `Sources/AISpendProviders/Resources/model-prices.json`
- Create: `Tests/AISpendProvidersTests/PriceCatalogTests.swift`
- Create: `Tests/AISpendProvidersTests/ClaudeLogScannerTests.swift`
- Create: `Tests/AISpendProvidersTests/CodexLogScannerTests.swift`
- Create: `Tests/AISpendProvidersTests/Fixtures/claude-session.jsonl`
- Create: `Tests/AISpendProvidersTests/Fixtures/codex-session.jsonl`

**Interfaces:**
- Consumes: allowlisted session roots, `MonthWindow`, `PriceCatalog`.
- Produces: model-level estimated `SpendRecord` values.

- [ ] **Step 1: Add sanitized fixtures and failing scanner tests**

Fixtures must contain:

- Claude usage with uncached input, cache creation, cache read, and output tokens;
- Codex usage with input, cached input, and output tokens;
- duplicate event IDs;
- an event outside the requested month;
- malformed unrelated lines that should produce diagnostics but not abort the scan.

Assert exact decimal calculation and one-record-per-provider/model/day normalization:

```swift
XCTAssertEqual(records.count, 1)
XCTAssertEqual(records[0].quality, .estimated)
XCTAssertEqual(records[0].model, "claude-sonnet-4-5")
XCTAssertEqual(records[0].estimate?.catalogVersion, "2026-07-27")
```

- [ ] **Step 2: Verify failure**

Run: `rtk swift test --filter 'PriceCatalogTests|ClaudeLogScannerTests|CodexLogScannerTests'`

Expected: FAIL because estimation types are missing.

- [ ] **Step 3: Implement the versioned catalog and calculation**

Use a resource schema with no implicit fallback:

```json
{
  "version": "2026-07-27",
  "currency": "USD",
  "models": {
    "claude-sonnet-4-5": {
      "inputPerMillion": "3.00",
      "cachedInputPerMillion": "0.30",
      "outputPerMillion": "15.00"
    },
    "gpt-5.5-codex": {
      "inputPerMillion": "1.25",
      "cachedInputPerMillion": "0.125",
      "outputPerMillion": "10.00"
    }
  }
}
```

Before committing implementation, verify every checked-in price against the official provider pricing page and record the source URL beside each model in the JSON. Unknown models yield an unavailable-estimate diagnostic; never silently use a nearby model's price.

Implement:

```swift
public struct LocalUsage: Hashable, Sendable {
    public let eventID: String
    public let timestamp: Date
    public let model: String
    public let inputTokens: Int
    public let cachedInputTokens: Int
    public let outputTokens: Int
}

public struct PriceCatalog: Sendable {
    public static func bundled() throws -> PriceCatalog
    public func estimate(_ usage: LocalUsage) throws -> Money
}
```

- [ ] **Step 4: Implement bounded log scanners**

Scan only known Claude/Codex session directories, only files whose modification time can intersect the requested month, and stream lines rather than loading whole files. Deduplicate event IDs and aggregate by local-calendar day and model. Generate deterministic observation IDs from provider, model, day, and sorted source event IDs.

- [ ] **Step 5: Run scanner tests and commit**

Run: `rtk swift test --filter 'PriceCatalogTests|ClaudeLogScannerTests|CodexLogScannerTests'`

Expected: PASS.

Commit:

```bash
rtk git add Sources/AISpendProviders/Estimation Sources/AISpendProviders/Resources Tests/AISpendProvidersTests
rtk git commit -m "feat: estimate local Claude and Codex spend"
```

---

### Task 7: Implement Actual-Cost Provider Clients and Strategy Fallback

**Files:**
- Create: `Sources/AISpendProviders/Providers/Claude/ClaudeCostClient.swift`
- Create: `Sources/AISpendProviders/Providers/Claude/ClaudeAdapter.swift`
- Create: `Sources/AISpendProviders/Providers/OpenAI/OpenAICostClient.swift`
- Create: `Sources/AISpendProviders/Providers/OpenAI/OpenAIAdapter.swift`
- Create: `Sources/AISpendProviders/Providers/Cursor/CursorUsageClient.swift`
- Create: `Sources/AISpendProviders/Providers/Cursor/CursorAdapter.swift`
- Create: `Tests/AISpendProvidersTests/ClaudeAdapterTests.swift`
- Create: `Tests/AISpendProvidersTests/OpenAIAdapterTests.swift`
- Create: `Tests/AISpendProvidersTests/CursorAdapterTests.swift`
- Create: `Tests/AISpendProvidersTests/Fixtures/anthropic-cost-report.json`
- Create: `Tests/AISpendProvidersTests/Fixtures/openai-costs.json`
- Create: `Tests/AISpendProvidersTests/Fixtures/cursor-spend.json`
- Create: `Tests/AISpendProvidersTests/Fixtures/cursor-usage-events.json`

**Interfaces:**
- Consumes: source hosts, local scanners, `MonthWindow`.
- Produces: three `ProviderAdapter` implementations emitting normalized records and source attempts.

- [ ] **Step 1: Add API fixtures and failing client tests**

Cover:

- Anthropic daily cost buckets grouped by description/model, including token, web-search, and code-execution costs in fractional cents;
- OpenAI paginated organization cost buckets with decimal USD;
- Cursor paginated team spend with `spendCents`;
- Cursor paginated usage events with `kind`, model, usage-based flag, timestamp, and `tokenUsage.totalCents`;
- exclusion of Cursor `Included in Business` and seat events;
- reconciliation of Cursor's authoritative team total with model-attributed event costs;
- 401/403 actual-source failure followed by Claude/Codex local estimate fallback;
- Cursor unavailable when neither authenticated app state nor admin credential exists.

- [ ] **Step 2: Verify failure**

Run: `rtk swift test --filter 'ClaudeAdapterTests|OpenAIAdapterTests|CursorAdapterTests'`

Expected: FAIL because provider clients and adapters are missing.

- [ ] **Step 3: Implement Anthropic actual-cost fetch**

Call:

`GET https://api.anthropic.com/v1/organizations/cost_report`

with daily buckets, month start/end, grouping by description, `anthropic-version: 2023-06-01`, and either an existing admin key or `org:admin` bearer token. Follow `next_page` until `has_more` is false. Convert lowest-unit decimal strings to USD by dividing by 100 with `Decimal`.

`ClaudeAdapter` strategy order:

1. admin cost report;
2. local Claude Code estimates.

Always run the estimate source after actual fetch succeeds so reconciliation can fill uncovered intervals. Record auth-scope failures as redacted attempts.

- [ ] **Step 4: Implement OpenAI actual-cost fetch**

Call:

`GET https://api.openai.com/v1/organization/costs`

with month start, end, one-day buckets, pagination, and an existing organization admin bearer token. Decode amount/currency as decimal strings or JSON numbers through `Decimal`, reject non-USD rows, and preserve project/model detail when exposed.

`OpenAIAdapter` strategy order:

1. organization costs;
2. local Codex estimates.

- [ ] **Step 5: Implement Cursor metered usage fetch**

Use Cursor Admin API Basic authentication when an existing admin key is available. Otherwise use the discovered Cursor application token/team context only through the documented Cursor usage endpoint when it authorizes successfully.

Call both:

`POST https://api.cursor.com/teams/spend`

and:

`POST https://api.cursor.com/teams/filtered-usage-events`

Page through `/teams/spend` and sum `spendCents` for the authoritative current-calendar-month provider total. Query usage events for the same month, include only `kind == "Usage-based"` token-based events, and use `tokenUsage.totalCents` for model attribution. Ignore `requestsCosts`, which is denominated in request units rather than money. Exclude included-plan events and team/seat billing.

If model-attributed event cents are less than the team spend total, emit the positive remainder as model `unknown`. If model-attributed event cents exceed the team spend total, emit the authoritative team spend as model `unknown`, omit the conflicting model allocations, and add a redacted schema-mismatch diagnostic. Never scale or guess model costs.

- [ ] **Step 6: Run adapter tests**

Run: `rtk swift test --filter 'ClaudeAdapterTests|OpenAIAdapterTests|CursorAdapterTests'`

Expected: PASS for parsing, pagination, filtering, fallback, and unavailable states.

- [ ] **Step 7: Commit**

```bash
rtk git add Sources/AISpendProviders/Providers Tests/AISpendProvidersTests
rtk git commit -m "feat: fetch provider billing data"
```

---

### Task 8: Coordinate Refreshes and Preserve Partial Results

**Files:**
- Create: `Sources/AISpendCore/Refresh/RefreshCoordinator.swift`
- Create: `Tests/AISpendCoreTests/RefreshCoordinatorTests.swift`

**Interfaces:**
- Consumes: enabled providers, `[ProviderAdapter]`, repository, reconciler, aggregator, pacing engine, clock/calendar.
- Produces: `RefreshSnapshot` for UI and alerts.

- [ ] **Step 1: Write failing concurrency and failure tests**

Use adapters that record whether `fetch` was invoked. Assert:

- disabled adapters are never called;
- enabled adapters run concurrently;
- a thrown Claude error preserves stored Claude records and still stores successful OpenAI records;
- each adapter times out after 20 seconds through an injected test timeout;
- the returned snapshot is partial with a redacted Claude failure;
- opening the popover does not refresh if the last attempt is less than one minute old.

- [ ] **Step 2: Verify failure**

Run: `rtk swift test --filter RefreshCoordinatorTests`

Expected: FAIL because `RefreshCoordinator` is missing.

- [ ] **Step 3: Implement refresh orchestration**

```swift
public struct RefreshSnapshot: Sendable {
    public let summary: MonthlySummary
    public let pacing: PacingResult
    public let attempts: [ProviderID: [SourceAttempt]]
    public let refreshedAt: Date
}

@MainActor
public final class RefreshCoordinator {
    public func refresh(reason: RefreshReason) async -> RefreshSnapshot
    public func cachedSnapshot() throws -> RefreshSnapshot
}
```

Capture enabled providers before starting tasks. Use `withTaskGroup` so provider failures become values and do not cancel siblings. Reconcile and persist only successful provider results. Re-read the ledger after persistence, aggregate enabled providers, then evaluate pacing. Track launch, periodic, popover, manual, and provider-enabled reasons; only popover refresh has the one-minute freshness guard.

- [ ] **Step 4: Run coordinator tests and commit**

Run: `rtk swift test --filter RefreshCoordinatorTests`

Expected: PASS.

Commit:

```bash
rtk git add Sources/AISpendCore/Refresh Tests/AISpendCoreTests/RefreshCoordinatorTests.swift
rtk git commit -m "feat: coordinate provider refreshes"
```

---

### Task 9: Implement Immediate and Daily Budget Alerts

**Files:**
- Create: `Sources/AISpendCore/Alerts/BudgetAlertEngine.swift`
- Create: `Sources/AISpendBar/BudgetNotificationClient.swift`
- Create: `Tests/AISpendCoreTests/BudgetAlertEngineTests.swift`

**Interfaces:**
- Consumes: `PacingResult`, monthly summary, stored per-budget alert state, local calendar.
- Produces: `[BudgetAlertDecision]` and a macOS notification client.

- [ ] **Step 1: Write failing alert state-machine tests**

Test:

- on-pace to off-pace sends `.immediate`;
- a second evaluation on the same day sends nothing;
- the next local day while still off pace sends `.dailyReminder`;
- returning on pace resets state;
- another off-pace transition sends another immediate alert;
- unknown, disabled, and all-stale states send nothing;
- two off-pace budgets each receive independent decisions.

- [ ] **Step 2: Verify failure**

Run: `rtk swift test --filter BudgetAlertEngineTests`

Expected: FAIL because the alert engine is missing.

- [ ] **Step 3: Implement pure alert decisions**

```swift
public enum BudgetAlertKind: Sendable {
    case immediate
    case dailyReminder
}

public struct BudgetAlertDecision: Sendable {
    public let budgetID: UUID
    public let kind: BudgetAlertKind
    public let title: String
    public let body: String
    public let nextState: StoredBudgetAlertState
}

public struct BudgetAlertEngine: Sendable {
    public func decisions(
        pacing: PacingResult,
        summary: MonthlySummary,
        budgets: [BudgetDefinition],
        storedStates: [UUID: StoredBudgetAlertState],
        now: Date,
        calendar: Calendar,
        allDataIsStale: Bool
    ) -> [BudgetAlertDecision]
}
```

Notification body must contain current spend, projection, budget, and largest provider. Persist `nextState` only after the notification client accepts the request.

- [ ] **Step 4: Add UserNotifications delivery**

`BudgetNotificationClient` requests authorization when the first enabled budget is created. Use identifiers `budget-<uuid>-<local-day>-<kind>` so retries do not duplicate notifications.

- [ ] **Step 5: Run tests and commit**

Run: `rtk swift test --filter BudgetAlertEngineTests`

Expected: PASS.

Commit:

```bash
rtk git add Sources/AISpendCore/Alerts Sources/AISpendBar/BudgetNotificationClient.swift Tests/AISpendCoreTests
rtk git commit -m "feat: alert on off-pace budgets"
```

---

### Task 10: Build the Menu Bar Popover and Provider Drill-Down

**Files:**
- Create: `Sources/AISpendUI/SpendFormatting.swift`
- Create: `Sources/AISpendUI/Menu/SpendPopoverView.swift`
- Create: `Sources/AISpendUI/Menu/BudgetPaceRow.swift`
- Create: `Sources/AISpendUI/Menu/ProviderRow.swift`
- Create: `Sources/AISpendUI/Menu/ProviderDetailView.swift`
- Create: `Sources/AISpendUI/AppModel.swift`
- Create: `Sources/AISpendBar/AISpendBarApp.swift`
- Create: `Sources/AISpendBar/Resources/Info.plist`
- Delete: `Sources/AISpendBar/AISpendBarBootstrap.swift`
- Create: `Tests/AISpendUITests/SpendFormattingTests.swift`
- Create: `Tests/AISpendUITests/AppModelTests.swift`

**Interfaces:**
- Consumes: `RefreshSnapshot`, coordinator, provider and budget settings actions.
- Produces: dynamic `MenuBarExtra`, popover navigation, refresh and settings controls.

- [ ] **Step 1: Write failing formatting and model tests**

Assert:

```swift
XCTAssertEqual(SpendFormatting.menuBar(Money(Decimal(string: "684.27")!)), "$684.27")
XCTAssertEqual(SpendFormatting.estimated(Money(Decimal(string: "63.20")!)), "~$63.20")
```

With a deterministic coordinator fake, assert `AppModel.popoverOpened()` refreshes when stale, `refresh()` publishes loading without removing the old snapshot, and selecting a provider exposes the correct provider summary.

- [ ] **Step 2: Verify failure**

Run: `rtk swift test --filter 'SpendFormattingTests|AppModelTests'`

Expected: FAIL because UI and app model do not exist.

- [ ] **Step 3: Implement the main-actor model**

```swift
@MainActor
@Observable
public final class AppModel {
    public private(set) var snapshot: RefreshSnapshot
    public private(set) var isRefreshing = false
    public var selectedProvider: ProviderID?
    public func launch() async
    public func popoverOpened() async
    public func refresh() async
}
```

Keep the last snapshot visible during refresh. Expose a status title, partial/stale indicator, sorted budget evaluations, provider summaries, and provider diagnostics as derived properties.

- [ ] **Step 4: Implement the menu hierarchy**

Use:

```swift
@main
struct AISpendBarApp: App {
    @State private var model: AppModel

    var body: some Scene {
        MenuBarExtra {
            SpendPopoverView(model: model)
                .frame(width: 360, height: 520)
        } label: {
            Label(model.statusTitle, systemImage: model.statusSymbol)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
}
```

The popover must show month, total, actual/estimated split, projection, all budget rows, provider rows, freshness, refresh, and settings. Provider selection switches to detail with model rows, shares, estimated badges, daily sparkline, source state, diagnostics, and dashboard link.

- [ ] **Step 5: Run tests and build**

Run: `rtk swift test --filter 'SpendFormattingTests|AppModelTests'`

Expected: PASS.

Run: `rtk swift build`

Expected: build succeeds with Swift 6 strict concurrency.

- [ ] **Step 6: Commit**

```bash
rtk git add Sources/AISpendUI Sources/AISpendBar Tests/AISpendUITests
rtk git commit -m "feat: add spend menu bar interface"
```

---

### Task 11: Add Provider, Budget, Privacy, and Diagnostics Settings

**Files:**
- Modify: `Sources/AISpendUI/AppModel.swift`
- Create: `Sources/AISpendUI/Settings/SettingsView.swift`
- Create: `Sources/AISpendUI/Settings/ProviderSettingsView.swift`
- Create: `Sources/AISpendUI/Settings/BudgetSettingsView.swift`
- Create: `Sources/AISpendUI/Settings/PrivacySettingsView.swift`
- Create: `Sources/AISpendUI/Diagnostics/ProviderDiagnosticsView.swift`
- Create: `Tests/AISpendUITests/SettingsModelTests.swift`

**Interfaces:**
- Consumes: repository/coordinator actions exposed by `AppModel`.
- Produces: provider toggles, multiple budget CRUD, privacy toggle, redacted diagnostics.

- [ ] **Step 1: Write failing settings behavior tests**

Assert:

- disabling Claude updates persistence before recalculating and never invokes the Claude adapter afterward;
- re-enabling Claude triggers refresh;
- adding `$500` and `$1,500` succeeds and sorts ascending;
- adding a duplicate `$500`, zero, or negative budget produces a validation message;
- removing a budget also removes its alert state;
- disabling browser-session discovery affects all browser strategies but not CLI/local-log strategies;
- diagnostic text has already passed through `Redactor`.

- [ ] **Step 2: Verify failure**

Run: `rtk swift test --filter SettingsModelTests`

Expected: FAIL because settings actions and views are missing.

- [ ] **Step 3: Add explicit settings actions to `AppModel`**

```swift
public func setProvider(_ provider: ProviderID, enabled: Bool) async
public func addBudget(decimalText: String) async -> BudgetValidationResult
public func updateBudget(_ budget: BudgetDefinition) async -> BudgetValidationResult
public func removeBudget(id: UUID) async
public func setBrowserDiscoveryEnabled(_ enabled: Bool) async
```

Persist provider disabled state before canceling/inhibiting refresh. Validate money with `Decimal(string:locale:)` using a fixed POSIX parsing locale, then display localized USD.

- [ ] **Step 4: Implement settings views**

Use a three-tab `SettingsView`:

- Providers: name, icon, enabled toggle, discovery state, active source, last success, diagnostics button.
- Budgets: editable positive USD limits, enabled toggles, current state/margin, add/remove actions.
- Privacy: browser discovery toggle, permission explanations, no-telemetry statement, local data location.

Do not include a credential text field or paste action anywhere.

- [ ] **Step 5: Run tests and commit**

Run: `rtk swift test --filter SettingsModelTests`

Expected: PASS.

Commit:

```bash
rtk git add Sources/AISpendUI/Settings Sources/AISpendUI/Diagnostics Sources/AISpendUI/AppModel.swift Tests/AISpendUITests
rtk git commit -m "feat: add providers and budget settings"
```

---

### Task 12: Package, Smoke-Test, and Document the App

**Files:**
- Create: `Scripts/package_app.sh`
- Create: `Tests/Smoke/app_bundle_test.sh`
- Create: `README.md`
- Modify: `.gitignore`
- Modify: `Sources/AISpendBar/AISpendBarApp.swift`

**Interfaces:**
- Consumes: release SwiftPM executable and resource bundle.
- Produces: ad-hoc-signed `AISpendBar.app`, launch instructions, verified menu-bar-only behavior.

- [ ] **Step 1: Write a failing bundle smoke test**

`Tests/Smoke/app_bundle_test.sh` must assert:

```bash
test -x AISpendBar.app/Contents/MacOS/AISpendBar
test "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' AISpendBar.app/Contents/Info.plist)" = "true"
codesign --verify --deep --strict AISpendBar.app
```

Run: `rtk bash Tests/Smoke/app_bundle_test.sh`

Expected: FAIL because `AISpendBar.app` does not exist.

- [ ] **Step 2: Implement deterministic app packaging**

`Scripts/package_app.sh` must:

1. run `swift build -c release`;
2. recreate only the explicit workspace path `AISpendBar.app`;
3. copy the release executable to `Contents/MacOS/AISpendBar`;
4. copy the executable resource bundle to `Contents/Resources`;
5. copy `Sources/AISpendBar/Resources/Info.plist` to `Contents/Info.plist`;
6. ad-hoc sign with `codesign --force --deep --sign - AISpendBar.app`.

The plist must include:

- `CFBundleIdentifier = com.ashercohen.AISpendBar`
- `CFBundleName = AI Spend`
- `CFBundleExecutable = AISpendBar`
- `CFBundlePackageType = APPL`
- `LSUIElement = true`

- [ ] **Step 3: Add launch and periodic refresh lifecycle**

On app launch, call `AppModel.launch()`. Schedule a cancellable 15-minute `ContinuousClock` loop while the app is active. Cancel it on termination. Popover-open refresh and manual refresh remain separate triggers.

- [ ] **Step 4: Document setup and source limitations**

`README.md` must explain:

- macOS 14 requirement;
- build, test, package, and launch commands;
- Cursor, Claude, and Codex/OpenAI source priority;
- actual versus estimated meaning;
- that normal CLI logins may not grant billing scope;
- provider toggles and multiple combined budgets;
- immediate plus daily alerts;
- permissions and local-only storage;
- fixed subscriptions are excluded;
- how to read redacted diagnostics.

- [ ] **Step 5: Run complete verification**

Run:

```bash
rtk swift format lint --recursive Sources Tests Package.swift
rtk swift test
rtk swift build -c release
rtk bash Scripts/package_app.sh
rtk bash Tests/Smoke/app_bundle_test.sh
rtk git diff --check
```

Expected: every command exits 0.

Launch:

`rtk open AISpendBar.app`

Manually verify:

- no Dock icon appears;
- menu bar shows a USD amount or explicit unavailable state;
- popover opens and refresh action works;
- provider toggles prevent disabled-provider work;
- `$500` and `$1,500` budgets coexist and show independent pace;
- provider detail lists models and estimated badges;
- diagnostics contain no secrets;
- notification permission is requested when the first enabled budget is created.

- [ ] **Step 6: Commit**

```bash
rtk git add Scripts Tests/Smoke README.md .gitignore Sources/AISpendBar
rtk git commit -m "build: package and verify AI Spend app"
```

---

## Final Acceptance Run

- [ ] Run `rtk swift test` and confirm all unit and integration tests pass.
- [ ] Run `rtk bash Scripts/package_app.sh` and confirm `AISpendBar.app` is produced.
- [ ] Run `rtk bash Tests/Smoke/app_bundle_test.sh` and confirm bundle metadata and signing pass.
- [ ] Run `rtk git status --short` and confirm only intentional plan-tracking edits remain.
- [ ] Compare the result against every acceptance criterion in `docs/superpowers/specs/2026-07-27-ai-spend-menu-bar-design.md`.
- [ ] Use the `superpowers:verification-before-completion` skill before reporting completion.
- [ ] Use the `superpowers:requesting-code-review` skill before integration.
