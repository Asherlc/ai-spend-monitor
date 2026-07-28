# Fireworks Provider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Fireworks as a default-enabled AI Spend provider that reuses a FireConnect login and combines rated current-month costs across every accessible Fireworks account.

**Architecture:** Extend the provider domain with persisted partial-coverage state, then add a Fireworks HTTP client and adapter behind the existing `ProviderAdapter` boundary. The adapter resolves the FireConnect Keychain credential, discovers accounts, fetches paginated day/model rated costs, falls back from account to self scope when necessary, and emits actual `SpendRecord` values into the existing ledger and aggregation pipeline.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Foundation `URLSession`, Security Keychain, XCTest, Swift Package Manager, Fireworks REST APIs.

## Global Constraints

- AI Spend continues to support macOS 14 Sonoma or later and USD only.
- FireConnect is the setup path; AI Spend does not install, configure, or shell out to FireConnect or `firectl`.
- Credential precedence is `FIREWORKS_API_KEY`, then Keychain service `FireworksAI` and account `fireworks-api-key`.
- AI Spend never persists or displays the Fireworks key, raw account names, display names, emails, user IDs, or API-key IDs.
- Every accessible Fireworks account is queried and combined.
- `ACCOUNT` scope falls back once to `SELF` on HTTP 401 or 403 and is visibly partial.
- Microsoft Foundry/Azure spend and local-log estimates are out of scope.
- All shell commands are prefixed with `rtk`.
- Every behavior change follows red-green-refactor.

---

### Task 1: Fireworks Provider Identity and Partial Coverage

**Files:**
- Modify: `Sources/AISpendCore/Domain/Provider.swift`
- Modify: `Sources/AISpendCore/Providers/ProviderAdapter.swift`
- Modify: `Sources/AISpendCore/Persistence/Models.swift`
- Modify: `Sources/AISpendCore/Refresh/RefreshCoordinator.swift`
- Modify: `Sources/AISpendCore/Ledger/SpendAggregator.swift`
- Modify: `Sources/AISpendUI/AppModel.swift`
- Modify: `Sources/AISpendUI/Settings/ProviderSettingsView.swift`
- Modify: `Sources/AISpendUI/Menu/ProviderRow.swift`
- Test: `Tests/AISpendCoreTests/DomainTests.swift`
- Test: `Tests/AISpendCoreTests/RefreshCoordinatorTests.swift`
- Test: `Tests/AISpendCoreTests/LedgerRepositoryTests.swift`
- Test: `Tests/AISpendUITests/AppModelTests.swift`

**Interfaces:**
- Consumes: Existing `ProviderID`, `ProviderFetchResult`, `StoredProviderState`, `Freshness`, and `ProviderFreshnessStatus`.
- Produces: `ProviderID.fireworks`, `ProviderDataCoverage`, `ProviderFetchResult.coverage`, and persisted `ProviderRefreshStatus.partial`.

- [ ] **Step 1: Write failing provider-domain and persistence tests**

Update the first-version provider assertion:

```swift
func testEveryBuiltInProviderHasDescriptor() {
  XCTAssertEqual(
    Set(ProviderID.allCases),
    [.cursor, .claude, .openAI, .fireworks]
  )
  XCTAssertEqual(ProviderDescriptor.builtIns.map(\.id), ProviderID.allCases)
}
```

Add a ledger round-trip assertion using the existing repository test factory:

```swift
func testProviderStateRoundTripsPartialRefreshStatus() throws {
  let repository = try makeRepository()
  let state = StoredProviderState(
    provider: .fireworks,
    isEnabled: true,
    lastAttemptAt: Date(timeIntervalSince1970: 200),
    lastSuccessfulAt: Date(timeIntervalSince1970: 200),
    refreshStatus: .partial,
    lastFailureMessage: "Only authenticated-user spend is available."
  )

  try repository.saveProviderState(state)

  XCTAssertEqual(try repository.providerStates()[.fireworks], state)
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
rtk swift test --filter DomainTests/testEveryBuiltInProviderHasDescriptor
rtk swift test --filter LedgerRepositoryTests/testProviderStateRoundTripsPartialRefreshStatus
```

Expected: compilation fails because `.fireworks` and `.partial` do not exist.

- [ ] **Step 3: Add the provider and coverage domain types**

Change the provider enum and descriptors to:

```swift
public enum ProviderID: String, Codable, CaseIterable, Sendable {
  case cursor
  case claude
  case openAI = "openai"
  case fireworks
}

public static let builtIns = [
  ProviderDescriptor(id: .cursor, displayName: "Cursor"),
  ProviderDescriptor(id: .claude, displayName: "Claude"),
  ProviderDescriptor(id: .openAI, displayName: "OpenAI"),
  ProviderDescriptor(id: .fireworks, displayName: "Fireworks"),
]
```

Add coverage to `ProviderAdapter.swift`:

```swift
public enum ProviderDataCoverage: Hashable, Sendable {
  case complete
  case partial(message: String)
}
```

Add the property and backwards-compatible initializer argument to
`ProviderFetchResult`:

```swift
public let coverage: ProviderDataCoverage

public init(
  provider: ProviderID,
  records: [SpendRecord],
  attempts: [SourceAttempt],
  refreshedSourceIDs: Set<String>,
  fetchedAt: Date,
  coverage: ProviderDataCoverage = .complete
) {
  self.provider = provider
  self.records = records
  self.attempts = attempts
  self.refreshedSourceIDs = refreshedSourceIDs
  self.fetchedAt = fetchedAt
  self.coverage = coverage
}
```

Add `case partial` to `ProviderRefreshStatus`.

- [ ] **Step 4: Write the failing coordinator partial-coverage test**

Use the existing adapter and repository spies:

```swift
func testPartialProviderCoverageKeepsFreshRecordsAndMarksSummaryPartial() async throws {
  let now = juneDate()
  let record = try makeSpendRecord(
    provider: .fireworks,
    amount: 4,
    quality: .actual
  )
  let adapter = AdapterSpy(
    provider: .fireworks,
    result: .success(
      ProviderFetchResult(
        provider: .fireworks,
        records: [record],
        attempts: [
          SourceAttempt(
            strategyID: "fireworks-self-costs",
            outcome: .succeeded(recordCount: 1)
          )
        ],
        refreshedSourceIDs: [record.sourceID],
        fetchedAt: now,
        coverage: .partial(
          message: "Only authenticated-user spend is available."
        )
      )
    )
  )
  let repository = InMemoryLedgerRepository(
    states: [.fireworks: StoredProviderState(provider: .fireworks, isEnabled: true)]
  )
  let coordinator = makeCoordinator(adapters: [adapter], repository: repository)

  let snapshot = await coordinator.refresh(reason: .manual)

  XCTAssertEqual(snapshot.summary.total, Money(4))
  XCTAssertTrue(snapshot.summary.isPartial)
  XCTAssertEqual(snapshot.providerStates[.fireworks]?.refreshStatus, .partial)
  XCTAssertEqual(snapshot.providerAvailability[.fireworks], .available)
}
```

Add the UI-model assertion:

```swift
func testPartialProviderStatePresentsLimitedFreshness() throws {
  let success = Date(timeIntervalSince1970: 100)
  let state = StoredProviderState(
    provider: .fireworks,
    isEnabled: true,
    lastAttemptAt: success,
    lastSuccessfulAt: success,
    refreshStatus: .partial,
    lastFailureMessage: "Only authenticated-user spend is available."
  )
  let snapshot = Self.snapshot(
    total: 1,
    providers: [
      ProviderSpendSummary(
        id: .fireworks,
        actual: Money(1),
        estimated: .zero,
        models: []
      )
    ],
    providerStates: [.fireworks: state],
    providerAvailability: [.fireworks: .available],
    refreshedAt: success,
    evaluatedAt: success
  )
  let model = AppModel(snapshot: snapshot, refresh: { _ in snapshot })

  guard case .partial(_, let message) = try XCTUnwrap(
    model.providerRows.first
  ).status.freshness else {
    return XCTFail("Expected limited provider freshness")
  }
  XCTAssertEqual(message, "Only authenticated-user spend is available.")
}
```

- [ ] **Step 5: Run the coordinator test and verify RED**

Run:

```bash
rtk swift test --filter RefreshCoordinatorTests/testPartialProviderCoverageKeepsFreshRecordsAndMarksSummaryPartial
rtk swift test --filter AppModelTests/testPartialProviderStatePresentsLimitedFreshness
```

Expected: FAIL because the coordinator ignores `ProviderFetchResult.coverage`.

- [ ] **Step 6: Persist and present partial coverage**

When a successful result is converted to `StoredProviderState`, resolve status
and message with:

```swift
let coverageMessage: String?
let refreshStatus: ProviderRefreshStatus
switch result.coverage {
case .complete:
  coverageMessage = failureMessage
  refreshStatus = failureMessage == nil ? .success : .failed
case .partial(let message):
  coverageMessage = message
  refreshStatus = .partial
}
```

Use `refreshStatus` and `coverageMessage` in the state while still setting
`lastSuccessfulAt` when at least one source refreshed.

Extend freshness:

```swift
public enum Freshness: Hashable, Sendable {
  case fresh
  case partial(age: TimeInterval, message: String)
  case stale(age: TimeInterval)
  case unavailable(message: String)
}
```

In `providerFreshness(for:now:)`, calculate age after validating
`lastSuccessfulAt`, return stale after 30 minutes, then return:

```swift
if state.refreshStatus == .partial {
  return .partial(
    age: age,
    message: state.lastFailureMessage ?? "Provider coverage is partial"
  )
}
return .fresh
```

Treat `.partial` as partial in `SpendAggregator.summarize`:

```swift
switch providerFreshness[provider] {
case .partial, .stale, .unavailable:
  true
case .fresh, .none:
  false
}
```

Add the matching UI case:

```swift
public enum ProviderFreshnessStatus: Hashable, Sendable {
  case fresh
  case partial(age: TimeInterval, message: String)
  case stale(age: TimeInterval)
  case cachedAfterFailure(age: TimeInterval, message: String)
  case unavailable(message: String)
}
```

Map `Freshness.partial` to that case in `AppModel`, show `Limited` in provider
settings, and show `Limited · <age>` in `ProviderRow` using the existing orange
status color.

- [ ] **Step 7: Run affected suites and verify GREEN**

Run:

```bash
rtk swift test --filter DomainTests
rtk swift test --filter LedgerRepositoryTests
rtk swift test --filter RefreshCoordinatorTests
rtk swift test --filter AppModelTests
```

Expected: PASS.

- [ ] **Step 8: Commit the core contract**

```bash
rtk git add Sources/AISpendCore Sources/AISpendUI Tests/AISpendCoreTests Tests/AISpendUITests
rtk git commit -m "feat: add Fireworks provider coverage state"
```

---

### Task 2: FireConnect Credential and Network Allowlisting

**Files:**
- Modify: `Sources/AISpendProviders/Hosting/CredentialHost.swift`
- Modify: `Sources/AISpendProviders/Hosting/HTTPClient.swift`
- Create: `Sources/AISpendProviders/Providers/Fireworks/FireworksCredential.swift`
- Test: `Tests/AISpendProvidersTests/CredentialHostTests.swift`
- Test: `Tests/AISpendProvidersTests/HTTPClientTests.swift`
- Create: `Tests/AISpendProvidersTests/FireworksCredentialTests.swift`

**Interfaces:**
- Consumes: `CredentialHost.environmentSecret(named:)` and
  `CredentialHost.keychainSecret(service:account:)`.
- Produces: `FireworksCredential.resolve(from:) -> Secret?` and permission for
  HTTPS requests to exact host `api.fireworks.ai`.

- [ ] **Step 1: Write failing credential tests**

```swift
func testFireworksCredentialUsesEnvironmentBeforeFireConnectKeychain() throws {
  let invocations = KeychainInvocationRecorder()
  let host = CredentialHost(
    homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
    environment: ["FIREWORKS_API_KEY": "fw_environment"],
    keychainLookup: { service, account in
      invocations.record(service: service, account: account)
      return Data("fw_keychain".utf8)
    }
  )

  let secret = try XCTUnwrap(FireworksCredential.resolve(from: host))

  XCTAssertEqual(secret.withValue { $0 }, "fw_environment")
  XCTAssertNil(invocations.credential)
}

func testFireworksCredentialFallsBackToFireConnectKeychain() throws {
  let invocations = KeychainInvocationRecorder()
  let host = CredentialHost(
    homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
    environment: [:],
    keychainLookup: { service, account in
      invocations.record(service: service, account: account)
      return Data("fw_keychain".utf8)
    }
  )

  let secret = try XCTUnwrap(FireworksCredential.resolve(from: host))

  XCTAssertEqual(secret.withValue { $0 }, "fw_keychain")
  XCTAssertEqual(
    invocations.credential,
    KeychainCredential(service: "FireworksAI", account: "fireworks-api-key")
  )
}
```

Add an HTTP policy test:

```swift
func testAllowsExactFireworksAPIHost() async throws {
  TestURLProtocol.state.setMode(.success)
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [TestURLProtocol.self]
  let client = HTTPClient(configuration: configuration)
  let request = URLRequest(
    url: URL(string: "https://api.fireworks.ai/v1/accounts")!
  )

  let (_, response) = try await client.data(for: request)

  XCTAssertEqual(response.statusCode, 200)
}
```

- [ ] **Step 2: Run focused tests and verify RED**

```bash
rtk swift test --filter FireworksCredentialTests
rtk swift test --filter HTTPClientTests/testAllowsExactFireworksAPIHost
```

Expected: the credential type is missing and Fireworks requests are rejected.

- [ ] **Step 3: Implement the exact credential resolver**

Add `FIREWORKS_API_KEY` to `allowedEnvironmentNames` and
`KeychainCredential(service: "FireworksAI", account: "fireworks-api-key")` to
`allowedKeychainCredentials`.

Create:

```swift
import Foundation

enum FireworksCredential {
  static let keychain = KeychainCredential(
    service: "FireworksAI",
    account: "fireworks-api-key"
  )

  static func resolve(from host: CredentialHost) throws -> Secret? {
    if let environment = try host.environmentSecret(named: "FIREWORKS_API_KEY") {
      return environment
    }
    return try host.keychainSecret(
      service: keychain.service,
      account: keychain.account
    )
  }
}
```

Add `"api.fireworks.ai"` to `HTTPRequestPolicy.allowedHosts`. Authorization is
already in `sensitiveHeaders`, so no new redirect header entry is needed.

- [ ] **Step 4: Run tests and verify GREEN**

```bash
rtk swift test --filter FireworksCredentialTests
rtk swift test --filter CredentialHostTests
rtk swift test --filter HTTPClientTests
```

Expected: PASS.

- [ ] **Step 5: Commit credential discovery**

```bash
rtk git add Sources/AISpendProviders/Hosting Sources/AISpendProviders/Providers/Fireworks Tests/AISpendProvidersTests
rtk git commit -m "feat: discover FireConnect credentials"
```

---

### Task 3: Fireworks Account Discovery Client

**Files:**
- Create: `Sources/AISpendProviders/Providers/Fireworks/FireworksCostClient.swift`
- Create: `Tests/AISpendProvidersTests/FireworksCostClientTests.swift`
- Create: `Tests/AISpendProvidersTests/Fixtures/fireworks-accounts-page.json`

**Interfaces:**
- Consumes: `Secret` and `HTTPClient.data(for:)`.
- Produces: `FireworksAccount`, `FireworksCostClient.accounts(credential:)`.

- [ ] **Step 1: Add the account fixture**

```json
{
  "accounts": [
    {
      "name": "accounts/personal",
      "displayName": "Personal",
      "email": "private@example.test"
    },
    {
      "name": "accounts/work",
      "displayName": "Work",
      "email": "private-work@example.test"
    }
  ],
  "nextPageToken": "accounts-page-2",
  "totalSize": 2
}
```

- [ ] **Step 2: Write the failing account pagination test**

```swift
func testAccountsPaginatesAndReturnsOnlyResourceNames() async throws {
  let requests = RequestRecorder()
  let first = try fixtureData("fireworks-accounts-page")
  let client = FireworksCostClient(http: { request in
    requests.append(request)
    let body = requests.count == 1
      ? first
      : Data(#"{"accounts":[],"nextPageToken":""}"#.utf8)
    return (body, response(for: request, status: 200))
  })

  let accounts = try await client.accounts(credential: Secret("fw_secret"))

  XCTAssertEqual(
    accounts,
    [
      FireworksAccount(resourceName: "accounts/personal", id: "personal"),
      FireworksAccount(resourceName: "accounts/work", id: "work"),
    ]
  )
  XCTAssertEqual(requests.count, 2)
  XCTAssertTrue(
    requests.requests[1].url!.absoluteString.contains(
      "pageToken=accounts-page-2"
    )
  )
  XCTAssertEqual(
    requests.requests[0].value(forHTTPHeaderField: "Authorization"),
    "Bearer fw_secret"
  )
}
```

Also add repeated-token and malformed-resource tests. The repeated-token test
returns `nextPageToken: "same"` twice and expects
`ProviderClientError.invalidResponse`. The malformed-resource test returns
`"name":"projects/not-an-account"` and expects the same error.

- [ ] **Step 3: Run the client test and verify RED**

```bash
rtk swift test --filter FireworksCostClientTests/testAccountsPaginatesAndReturnsOnlyResourceNames
```

Expected: compilation fails because `FireworksCostClient` does not exist.

- [ ] **Step 4: Implement account discovery**

Create these interfaces:

```swift
struct FireworksAccount: Hashable, Sendable {
  let resourceName: String
  let id: String
}

struct FireworksCostClient: Sendable {
  typealias Transport =
    @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

  private let http: Transport

  init(http: @escaping Transport) {
    self.http = http
  }

  init(httpClient: HTTPClient = HTTPClient()) {
    http = { request in try await httpClient.data(for: request) }
  }
}
```

Decode only the `name` field:

```swift
private struct FireworksAccountsPage: Decodable {
  let accounts: [FireworksAccountPayload]
  let nextPageToken: String?
}

private struct FireworksAccountPayload: Decodable {
  let name: String
}
```

Implement `accounts` with a 100-page cap, a set of requested page tokens, an
`Authorization: Bearer` header, `pageSize=200`, and optional `pageToken`.
Convert only names with exactly two slash-separated components whose first
component is `accounts` and whose ID is non-empty:

```swift
private static func account(from name: String) throws -> FireworksAccount {
  let components = name.split(separator: "/", omittingEmptySubsequences: false)
  guard components.count == 2,
    components[0] == "accounts",
    !components[1].isEmpty
  else {
    throw ProviderClientError.invalidResponse
  }
  return FireworksAccount(resourceName: name, id: String(components[1]))
}
```

- [ ] **Step 5: Run client tests and verify GREEN**

```bash
rtk swift test --filter FireworksCostClientTests
```

Expected: PASS.

- [ ] **Step 6: Commit account discovery**

```bash
rtk git add Sources/AISpendProviders/Providers/Fireworks Tests/AISpendProvidersTests
rtk git commit -m "feat: discover Fireworks accounts"
```

---

### Task 4: Fireworks Rated Cost Query Client

**Files:**
- Create: `Sources/AISpendProviders/Hosting/ProviderClientError.swift`
- Modify: `Sources/AISpendProviders/Providers/Claude/ClaudeCostClient.swift`
- Modify: `Sources/AISpendProviders/Providers/Fireworks/FireworksCostClient.swift`
- Modify: `Tests/AISpendProvidersTests/FireworksCostClientTests.swift`
- Create: `Tests/AISpendProvidersTests/Fixtures/fireworks-costs-page.json`

**Interfaces:**
- Consumes: `FireworksAccount`, `MonthWindow`, `Secret`.
- Produces: `FireworksCostScope`, `FireworksCostRow`,
  `FireworksCostResult`, and
  `FireworksCostClient.costs(account:window:scope:credential:)`.

- [ ] **Step 1: Add the rated-cost fixture**

```json
{
  "rows": [
    {
      "dimensions": {
        "startTime": "2026-06-01T00:00:00Z",
        "model": "accounts/fireworks/models/kimi-k2",
        "unknownModel": false
      },
      "subtotal": {
        "currencyCode": "USD",
        "units": "1",
        "nanos": 250000000
      }
    },
    {
      "dimensions": {
        "startTime": "2026-06-02T00:00:00Z",
        "unknownModel": true
      },
      "subtotal": {
        "currencyCode": "USD",
        "units": "0",
        "nanos": 750000000
      }
    }
  ],
  "nextPageToken": "cost-page-2",
  "subtotal": {
    "currencyCode": "USD",
    "units": "3",
    "nanos": 0
  },
  "evaluationTime": "2026-06-03T00:05:00Z",
  "attributionCompleteness": "COMPLETE"
}
```

- [ ] **Step 2: Write the failing request/decoding test**

```swift
func testCostsPostsDayModelQueryAndDecodesMoney() async throws {
  let requests = RequestRecorder()
  let first = try fixtureData("fireworks-costs-page")
  let client = FireworksCostClient(http: { request in
    requests.append(request)
    let body = requests.count == 1
      ? first
      : Data(
        #"{"rows":[],"nextPageToken":"","subtotal":{"currencyCode":"USD","units":"3","nanos":0}}"#.utf8
      )
    return (body, response(for: request, status: 200))
  })

  let result = try await client.costs(
    account: FireworksAccount(resourceName: "accounts/personal", id: "personal"),
    window: juneWindow(),
    scope: .account,
    credential: Secret("fw_secret")
  )

  XCTAssertEqual(result.rows.map(\.amount), [Decimal(string: "1.25")!, Decimal(string: "0.75")!])
  XCTAssertEqual(result.rows.map(\.model), ["accounts/fireworks/models/kimi-k2", "unknown"])
  XCTAssertEqual(result.subtotal, 3)
  XCTAssertEqual(requests.count, 2)
  XCTAssertEqual(requests.requests[0].httpMethod, "POST")
  let body = try JSONSerialization.jsonObject(
    with: try XCTUnwrap(requests.requests[0].httpBody)
  ) as! [String: Any]
  XCTAssertEqual(body["scope"] as? String, "ACCOUNT")
  XCTAssertEqual(body["groupBy"] as? [String], ["DAY", "MODEL"])
  XCTAssertEqual(body["pageSize"] as? Int, 1000)
  XCTAssertEqual(body["startTime"] as? String, "2026-06-01T00:00:00Z")
  XCTAssertEqual(body["endTime"] as? String, "2026-07-01T00:00:00Z")
}
```

Add tests that:

- reject `currencyCode` other than `USD` with
  `ProviderClientError.unsupportedCurrency`;
- reject negative nanos or nanos greater than `999_999_999`;
- reject repeated page tokens;
- expose HTTP 401 and 403 as `ProviderClientError.httpStatus`;
- clamp each row interval to the month window and use the next day as its
  exclusive end.

- [ ] **Step 3: Run focused tests and verify RED**

```bash
rtk swift test --filter FireworksCostClientTests/testCostsPostsDayModelQueryAndDecodesMoney
```

Expected: compilation fails because cost-query interfaces do not exist.

- [ ] **Step 4: Add exact cost-query interfaces**

```swift
enum FireworksCostScope: String, Sendable {
  case account = "ACCOUNT"
  case personal = "SELF"
}

struct FireworksCostRow: Hashable, Sendable {
  let start: Date
  let end: Date
  let model: String
  let amount: Decimal
}

struct FireworksCostResult: Sendable {
  let rows: [FireworksCostRow]
  let subtotal: Decimal
}
```

Use payload types:

```swift
private struct FireworksCostQuery: Encodable {
  let startTime: String
  let endTime: String
  let scope: String
  let groupBy = ["DAY", "MODEL"]
  let pageSize = 1000
  let pageToken: String?
}

private struct FireworksCostPage: Decodable {
  let rows: [FireworksCostPayload]
  let nextPageToken: String?
  let subtotal: FireworksMoneyPayload
}

private struct FireworksCostPayload: Decodable {
  let dimensions: FireworksDimensionsPayload
  let subtotal: FireworksMoneyPayload
}

private struct FireworksDimensionsPayload: Decodable {
  let startTime: String
  let model: String?
  let unknownModel: Bool?
}

private struct FireworksMoneyPayload: Decodable {
  let currencyCode: String
  let units: String
  let nanos: Int
}
```

Money conversion is:

```swift
func decimalAmount() throws -> Decimal {
  guard currencyCode == "USD" else {
    throw ProviderClientError.unsupportedCurrency
  }
  guard let whole = Decimal(
      string: units,
      locale: Locale(identifier: "en_US_POSIX")
    ),
    nanos >= 0,
    nanos <= 999_999_999
  else {
    throw ProviderClientError.invalidResponse
  }
  return whole + Decimal(nanos) / Decimal(1_000_000_000)
}
```

Add `case unsupportedCurrency` to `ProviderClientError`. The adapter maps it
to the fixed diagnostic `Fireworks returned an unsupported currency.` without
including response content.

Move the shared enum out of `ClaudeCostClient.swift` into
`Hosting/ProviderClientError.swift`:

```swift
enum ProviderClientError: Error, Equatable, Sendable {
  case httpStatus(Int)
  case invalidResponse
  case unsupportedCurrency
}
```

Build the account-specific URL by appending each path component so an account
ID cannot change the request host or query:

```swift
let url = URL(string: "https://api.fireworks.ai")!
  .appending(path: "v1")
  .appending(path: "accounts")
  .appending(path: account.id)
  .appending(path: "usageCosts:query")
```

Implement the same 100-page/repeated-token guard as account discovery. POST
JSON to the exact account path, set `Content-Type: application/json`,
`Accept: application/json`, and bearer authorization. Require every page's
query-wide subtotal to match the first page's subtotal.

- [ ] **Step 5: Run cost client tests and verify GREEN**

```bash
rtk swift test --filter FireworksCostClientTests
rtk swift test --filter HTTPClientTests
```

Expected: PASS.

- [ ] **Step 6: Commit the rated-cost client**

```bash
rtk git add Sources/AISpendProviders/Providers/Fireworks Tests/AISpendProvidersTests
rtk git commit -m "feat: query Fireworks rated costs"
```

---

### Task 5: Multi-account Fireworks Adapter

**Files:**
- Create: `Sources/AISpendProviders/Providers/Fireworks/FireworksAdapter.swift`
- Create: `Tests/AISpendProvidersTests/FireworksAdapterTests.swift`

**Interfaces:**
- Consumes: `FireworksCredential.resolve`, `FireworksCostClient.accounts`,
  `FireworksCostClient.costs`, `AccountFingerprinter`, and `ProviderDataCoverage`.
- Produces: public `FireworksAdapter: ProviderAdapter`.

- [ ] **Step 1: Write failing multi-account aggregation test**

```swift
func testCombinesEveryAccessibleAccountWithoutPersistingRawNames() async throws {
  let adapter = FireworksAdapter(
    credential: { Secret("fw_secret") },
    accounts: { _ in
      [
        FireworksAccount(resourceName: "accounts/personal", id: "personal"),
        FireworksAccount(resourceName: "accounts/work", id: "work"),
      ]
    },
    costs: { account, _, scope, _ in
      XCTAssertEqual(scope, .account)
      let amount: Decimal = account.id == "personal" ? 1 : 2
      return FireworksCostResult(
        rows: [
          FireworksCostRow(
            start: juneWindow().start,
            end: juneWindow().start.addingTimeInterval(86_400),
            model: "kimi-k2",
            amount: amount
          )
        ],
        subtotal: amount
      )
    },
    fingerprinter: AccountFingerprinter(key: Data(repeating: 7, count: 32)),
    now: { juneDate() }
  )

  let result = try await adapter.fetch(window: juneWindow())

  XCTAssertEqual(result.records.map(\.amount), [Money(1), Money(2)])
  XCTAssertEqual(result.records.map(\.quality), [.actual, .actual])
  XCTAssertEqual(result.coverage, .complete)
  XCTAssertEqual(result.refreshedSourceIDs.count, 2)
  let serialized = String(describing: result.records)
  XCTAssertFalse(serialized.contains("personal"))
  XCTAssertFalse(serialized.contains("work"))
}
```

- [ ] **Step 2: Write failing authorization fallback test**

```swift
func testAccountAuthorizationFailureFallsBackToPersonalAndMarksPartial() async throws {
  let scopes = ScopeRecorder()
  let adapter = FireworksAdapter(
    credential: { Secret("fw_secret") },
    accounts: { _ in
      [FireworksAccount(resourceName: "accounts/personal", id: "personal")]
    },
    costs: { _, _, scope, _ in
      scopes.append(scope)
      if scope == .account {
        throw ProviderClientError.httpStatus(403)
      }
      return FireworksCostResult(
        rows: [
          FireworksCostRow(
            start: juneWindow().start,
            end: juneWindow().start.addingTimeInterval(86_400),
            model: "unknown",
            amount: 1
          )
        ],
        subtotal: 1
      )
    },
    now: { juneDate() }
  )

  let result = try await adapter.fetch(window: juneWindow())

  XCTAssertEqual(scopes.values, [.account, .personal])
  XCTAssertEqual(result.records.map(\.amount), [Money(1)])
  guard case .partial(let message) = result.coverage else {
    return XCTFail("Expected partial coverage")
  }
  XCTAssertTrue(message.contains("authenticated-user"))
}
```

Add tests for:

- no credential returns zero records and an unavailable attempt naming
  `fireconnect login`;
- empty account discovery is unavailable;
- one account failure preserves another account's records and cache source ID;
- zero-cost success refreshes the source with zero records;
- subtotal greater than row sum adds an `unknown` record;
- row sum greater than subtotal fails that account;
- 401 and 403 trigger personal fallback, while 429 and 500 do not;
- `fpk_` authorization failure produces standard-key guidance;
- cancellation is rethrown.

- [ ] **Step 3: Run adapter tests and verify RED**

```bash
rtk swift test --filter FireworksAdapterTests
```

Expected: compilation fails because `FireworksAdapter` does not exist.

- [ ] **Step 4: Implement adapter dependency seams**

```swift
public struct FireworksAdapter: ProviderAdapter {
  public let provider = ProviderID.fireworks

  private let credential: @Sendable () throws -> Secret?
  private let accounts: @Sendable (Secret) async throws -> [FireworksAccount]
  private let costs:
    @Sendable (
      FireworksAccount,
      MonthWindow,
      FireworksCostScope,
      Secret
    ) async throws -> FireworksCostResult
  private let fingerprinter: AccountFingerprinter
  private let now: @Sendable () -> Date
  private let redactor: Redactor
}
```

The internal initializer accepts all five dependencies. The public initializer
constructs `FireworksCostClient` and resolves credentials through
`FireworksCredential`.

- [ ] **Step 5: Implement multi-account fetch and normalization**

Resolve the credential and accounts first. For each account:

```swift
let fingerprint = try fingerprinter.fingerprint(
  identity: credential,
  namespace: "fireworks-account:\(account.resourceName)"
)
let sourceID = "fireworks-usage-costs:\(fingerprint)"
```

Call account scope. On 401 or 403, retry personal scope and set:

```swift
coverage = .partial(
  message: "Only authenticated-user Fireworks spend is available for at least one account."
)
```

For any failed account, retain other account results and set:

```swift
coverage = .partial(
  message: "Some Fireworks account spend is unavailable."
)
```

Normalize each row with stable identifiers derived only from the fingerprint,
dates, model, and scope:

```swift
let observationID = stableIdentifier([
  "fireworks-cost",
  fingerprint,
  String(row.start.timeIntervalSince1970),
  String(row.end.timeIntervalSince1970),
  row.model,
  scope.rawValue,
])
```

Create actual records with the account-specific source ID. If row totals are
less than the query subtotal, add one `unknown` record spanning the window for
the positive difference. If row totals exceed subtotal, fail only that
account. Insert a source ID into `refreshedSourceIDs` even when a successful
query has zero rows.

Use these strategy IDs exactly:

```swift
"fireworks-credential"
"fireworks-account-discovery"
"fireworks-account-costs"
"fireworks-self-costs"
```

Return account/resource identifiers only through fingerprints; sanitize all
failure messages with `Redactor`.

- [ ] **Step 6: Run adapter tests and verify GREEN**

```bash
rtk swift test --filter FireworksAdapterTests
rtk swift test --filter FireworksCostClientTests
```

Expected: PASS.

- [ ] **Step 7: Commit the adapter**

```bash
rtk git add Sources/AISpendProviders/Providers/Fireworks Tests/AISpendProvidersTests
rtk git commit -m "feat: aggregate Fireworks account spend"
```

---

### Task 6: App Bootstrap, Provider UI, and Existing-Install Backfill

**Files:**
- Modify: `Sources/AISpendBar/AISpendBarApp.swift`
- Modify: `Sources/AISpendCore/Alerts/BudgetAlertEngine.swift`
- Modify: `Sources/AISpendUI/Menu/ProviderRow.swift`
- Modify: `README.md`
- Test: `Tests/AISpendBarTests/AppLifecycleControllerTests.swift`
- Test: `Tests/AISpendCoreTests/BudgetAlertEngineTests.swift`
- Test: `Tests/AISpendUITests/SettingsModelTests.swift`

**Interfaces:**
- Consumes: public `FireworksAdapter`.
- Produces: bootstrapped Fireworks refreshes, an enabled default for existing
  installs, Fireworks UI metadata, and setup documentation.

- [ ] **Step 1: Write failing bootstrap backfill test**

Extract provider default installation to an internal testable helper:

```swift
import SwiftData

@MainActor
func testProviderDefaultsBackfillOnlyMissingFireworksState() throws {
  let schema = Schema([
    SpendRecordEntity.self,
    ProviderStateEntity.self,
    BudgetEntity.self,
    BudgetAlertStateEntity.self,
  ])
  let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
  let container = try ModelContainer(
    for: schema,
    configurations: [configuration]
  )
  let repository = SwiftDataLedgerRepository(modelContainer: container)
  try repository.saveProviderState(
    StoredProviderState(provider: .claude, isEnabled: false)
  )

  try AppEnvironment.installProviderDefaultsIfNeeded(in: repository)

  let states = try repository.providerStates()
  XCTAssertFalse(try XCTUnwrap(states[.claude]).isEnabled)
  XCTAssertTrue(try XCTUnwrap(states[.fireworks]).isEnabled)
  XCTAssertEqual(Set(states.keys), Set(ProviderID.allCases))
}
```

- [ ] **Step 2: Write failing presentation assertions**

Add:

```swift
func testFireworksProviderPresentationMetadata() {
  XCTAssertEqual(ProviderID.fireworks.displayName, "Fireworks")
  XCTAssertEqual(ProviderID.fireworks.symbolName, "flame.fill")
  XCTAssertEqual(
    ProviderID.fireworks.dashboardURL,
    URL(string: "https://app.fireworks.ai/usage")
  )
}
```

Update any provider-count or provider-order assertions to include Fireworks.
Add a budget alert assertion that a Fireworks provider breakdown renders the
name `Fireworks`.

- [ ] **Step 3: Run focused tests and verify RED**

```bash
rtk swift test --filter AppLifecycleControllerTests/testProviderDefaultsBackfillOnlyMissingFireworksState
rtk swift test --filter SettingsModelTests/testFireworksProviderPresentationMetadata
rtk swift test --filter BudgetAlertEngineTests
```

Expected: missing adapter bootstrap, missing exhaustive switch cases, and the
current all-or-nothing provider default installer fails the backfill.

- [ ] **Step 4: Bootstrap Fireworks and backfill missing provider states**

Add `FireworksAdapter()` to the runtime adapter array:

```swift
let adapters: [any ProviderAdapter] = [
  CursorAdapter(browserDiscovery: browserDiscovery),
  ClaudeAdapter(scanner: ClaudeLogScanner(priceCatalog: catalog)),
  OpenAIAdapter(scanner: CodexLogScanner(priceCatalog: catalog)),
  FireworksAdapter(),
]
```

Replace the empty-store guard with:

```swift
let states = try repository.providerStates()
for descriptor in ProviderDescriptor.builtIns where states[descriptor.id] == nil {
  try repository.saveProviderState(
    StoredProviderState(provider: descriptor.id, isEnabled: true)
  )
}
```

Keep the method internal so `@testable import AISpendBar` can exercise it.

- [ ] **Step 5: Complete Fireworks presentation**

Add switch cases:

```swift
case .fireworks: "flame.fill"
```

```swift
case .fireworks: .red
```

```swift
case .fireworks: URL(string: "https://app.fireworks.ai/usage")
```

Add `"Fireworks"` to the budget alert display-name switch. Verify every
`ProviderID` switch compiles exhaustively.

- [ ] **Step 6: Document FireConnect setup and limitations**

Update the README opening provider list to include Fireworks. Add this provider
table row:

```markdown
| Fireworks | FireConnect Keychain login, or `FIREWORKS_API_KEY` | Authenticated-user rated costs when account-wide permission is unavailable |
```

Add a Fireworks section that states:

- install FireConnect using the official installer;
- run `fireconnect login`;
- AI Spend combines every accessible account;
- account scope falls back to personal scope with a visible partial state;
- Fireworks billing data may be delayed by several minutes;
- Fireworks on Microsoft Foundry/Azure is not included.

Do not include a literal API key in any example.

- [ ] **Step 7: Run integration-facing tests and verify GREEN**

```bash
rtk swift test --filter AppLifecycleControllerTests
rtk swift test --filter SettingsModelTests
rtk swift test --filter BudgetAlertEngineTests
```

Expected: PASS.

- [ ] **Step 8: Commit bootstrap, UI, and docs**

```bash
rtk git add Sources/AISpendBar Sources/AISpendCore/Alerts Sources/AISpendUI README.md Tests/AISpendBarTests Tests/AISpendCoreTests Tests/AISpendUITests
rtk git commit -m "feat: surface Fireworks spend in AI Spend"
```

---

### Task 7: Full Verification and Release Readiness

**Files:**
- Verify: `Sources/`
- Verify: `Tests/`
- Verify: `Package.swift`
- Verify: `Scripts/package_app.sh`
- Verify: `Tests/Smoke/app_bundle_test.sh`

**Interfaces:**
- Consumes: the complete Fireworks integration.
- Produces: a clean, tested, packageable application ready for review.

- [ ] **Step 1: Run formatter lint**

```bash
rtk swift format lint --recursive Sources Tests Package.swift
```

Expected: exit 0. If formatting fails, run:

```bash
rtk swift format --in-place --recursive Sources Tests Package.swift
```

Then rerun lint and require exit 0.

- [ ] **Step 2: Run the complete Swift test suite**

```bash
rtk swift test
```

Expected: every test passes with zero failures.

- [ ] **Step 3: Package and smoke-test the application**

```bash
rtk bash Scripts/package_app.sh
rtk bash Tests/Smoke/app_bundle_test.sh
```

Expected: package and bundle smoke tests pass, including the packaged runtime
self-check and code-signature verification.

- [ ] **Step 4: Inspect the final diff**

```bash
rtk git diff --check origin/master...
rtk git status --short
rtk git diff --stat origin/master...
```

Expected: no whitespace errors, no untracked fixtures or generated app bundle,
and only Fireworks/provider-coverage files differ from `origin/master`.

- [ ] **Step 5: Commit any verification-only corrections**

If formatter or an explicit smoke assertion changed tracked files:

```bash
rtk git add Sources Tests Package.swift
rtk git commit -m "test: verify Fireworks provider integration"
```

If no tracked files changed, do not create an empty commit.

- [ ] **Step 6: Run final verification after the last commit**

```bash
rtk swift test
rtk swift format lint --recursive Sources Tests Package.swift
rtk bash Scripts/package_app.sh
rtk bash Tests/Smoke/app_bundle_test.sh
```

Expected: all four commands exit 0.
