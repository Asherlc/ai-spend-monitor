import AISpendCore
import Foundation
import XCTest

@testable import AISpendProviders

final class FireworksAdapterTests: XCTestCase {
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
    XCTAssertEqual(Set(result.records.map(\.accountFingerprint)).count, 2)
    let privateIdentifiers = result.records.flatMap {
      [$0.accountFingerprint, $0.id, $0.observationID, $0.sourceID]
    }
    XCTAssertFalse(privateIdentifiers.contains { $0 == "personal" || $0.hasSuffix(":personal") })
    XCTAssertFalse(privateIdentifiers.contains { $0 == "work" || $0.hasSuffix(":work") })
  }

  func testAccountFingerprintAndSourceIDRemainStableAcrossCredentialRotation() async throws {
    func fetch(credential: String) async throws -> SpendRecord {
      let adapter = FireworksAdapter(
        credential: { Secret(credential) },
        accounts: { _ in
          [FireworksAccount(resourceName: "accounts/stable-account", id: "stable-account")]
        },
        costs: { _, _, _, _ in fireworksResult(amount: 1) },
        fingerprinter: AccountFingerprinter(key: Data(repeating: 7, count: 32)),
        now: { juneDate() }
      )
      let result = try await adapter.fetch(window: juneWindow())
      return try XCTUnwrap(result.records.first)
    }

    let beforeRotation = try await fetch(credential: "fw_old_secret")
    let afterRotation = try await fetch(credential: "fw_new_secret")

    XCTAssertEqual(beforeRotation.accountFingerprint, afterRotation.accountFingerprint)
    XCTAssertEqual(beforeRotation.sourceID, afterRotation.sourceID)
  }

  func testResourceQualifiedModelsRemoveAccountIdentityAndStillAggregateByModel() async throws {
    let rawAccountIDs = ["tenant-alpha-secret", "tenant-beta-secret"]
    let rawResourceNames = rawAccountIDs.map { "accounts/\($0)" }
    let adapter = FireworksAdapter(
      credential: { Secret("fw_secret") },
      accounts: { _ in
        zip(rawResourceNames, rawAccountIDs).map {
          FireworksAccount(resourceName: $0.0, id: $0.1)
        }
      },
      costs: { account, _, _, _ in
        fireworksResult(
          amount: 1,
          model: "\(account.resourceName)/models/kimi-k2"
        )
      },
      fingerprinter: AccountFingerprinter(key: Data(repeating: 4, count: 32)),
      now: { juneDate() }
    )

    let result = try await adapter.fetch(window: juneWindow())

    XCTAssertEqual(result.records.map(\.model), ["models/kimi-k2", "models/kimi-k2"])
    XCTAssertEqual(
      Dictionary(grouping: result.records, by: \.model).mapValues(\.count),
      ["models/kimi-k2": 2]
    )
    try assertNoFireworksIdentity(
      in: result,
      rawValues: rawAccountIDs + rawResourceNames
    )
  }

  func testOrdinaryModelContainingAccountIDSubstringIsUnchanged() async throws {
    let adapter = makeAdapter(
      account: FireworksAccount(resourceName: "accounts/work", id: "work")
    ) { _, _, _, _ in
      fireworksResult(amount: 1, model: "network-model")
    }

    let result = try await adapter.fetch(window: juneWindow())

    XCTAssertEqual(result.records.map(\.model), ["network-model"])
  }

  func testModelNormalizationAndObservationIDIgnoreUnrelatedSiblingAccounts() async throws {
    let primary = FireworksAccount(resourceName: "accounts/personal", id: "personal")
    let sibling = FireworksAccount(resourceName: "accounts/work", id: "work")

    func fetch(accounts: [FireworksAccount]) async throws -> SpendRecord {
      let adapter = FireworksAdapter(
        credential: { Secret("fw_secret") },
        accounts: { _ in accounts },
        costs: { account, _, _, _ in
          account.id == primary.id
            ? fireworksResult(amount: 1, model: "network-model")
            : fireworksResult(amount: 0)
        },
        fingerprinter: AccountFingerprinter(key: Data(repeating: 5, count: 32)),
        now: { juneDate() }
      )
      let result = try await adapter.fetch(window: juneWindow())
      return try XCTUnwrap(result.records.first)
    }

    let withoutSibling = try await fetch(accounts: [primary])
    let withSibling = try await fetch(accounts: [primary, sibling])

    XCTAssertEqual(withSibling.model, withoutSibling.model)
    XCTAssertEqual(withSibling.id, withoutSibling.id)
    XCTAssertEqual(withSibling.observationID, withoutSibling.observationID)
  }

  func testModelAndRouterResourcesCanonicalizeWithoutOwnerPath() async throws {
    let owner = "tenant-private"
    let adapter = makeAdapter(
      account: FireworksAccount(resourceName: "accounts/\(owner)", id: owner)
    ) { _, _, _, _ in
      FireworksCostResult(
        rows: [
          FireworksCostRow(
            start: juneWindow().start,
            end: juneWindow().start.addingTimeInterval(86_400),
            model: "accounts/\(owner)/models/kimi-k2",
            amount: 1
          ),
          FireworksCostRow(
            start: juneWindow().start,
            end: juneWindow().start.addingTimeInterval(86_400),
            model: "accounts/\(owner)/routers/fast",
            amount: 1
          ),
        ],
        subtotal: 2
      )
    }

    let result = try await adapter.fetch(window: juneWindow())

    XCTAssertEqual(result.records.map(\.model), ["models/kimi-k2", "routers/fast"])
    try assertNoFireworksIdentity(
      in: result,
      rawValues: [owner, "accounts/\(owner)"]
    )
  }

  func testAccountDiagnosticRedactsEveryDiscoveredAccountIdentity() async throws {
    let accounts = [
      FireworksAccount(resourceName: "accounts/tenant-alpha-private", id: "tenant-alpha-private"),
      FireworksAccount(resourceName: "accounts/tenant-beta-private", id: "tenant-beta-private"),
    ]
    let adapter = FireworksAdapter(
      credential: { Secret("fw_secret") },
      accounts: { _ in accounts },
      costs: { account, _, _, _ in
        if account.id == "tenant-alpha-private" {
          throw NSError(
            domain: "failed for accounts/tenant-beta-private id=tenant-beta-private",
            code: 1
          )
        }
        return fireworksResult(amount: 2)
      },
      fingerprinter: AccountFingerprinter(key: Data(repeating: 6, count: 32)),
      now: { juneDate() }
    )

    let result = try await adapter.fetch(window: juneWindow())

    XCTAssertEqual(result.records.map(\.amount), [Money(2)])
    try assertNoFireworksIdentity(
      in: result,
      rawValues: accounts.flatMap { [$0.id, $0.resourceName] }
    )
  }

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

  func testNoCredentialReturnsUnavailableSetupGuidance() async throws {
    let adapter = FireworksAdapter(
      credential: { nil },
      accounts: { _ in
        XCTFail("Account discovery must not run")
        return []
      },
      costs: { _, _, _, _ in
        XCTFail("Costs must not run")
        return fireworksResult(amount: 0)
      },
      now: { juneDate() }
    )

    let result = try await adapter.fetch(window: juneWindow())

    XCTAssertTrue(result.records.isEmpty)
    XCTAssertTrue(result.refreshedSourceIDs.isEmpty)
    XCTAssertEqual(result.attempts.map(\.strategyID), ["fireworks-credential"])
    guard case .unavailable(let reason) = result.attempts[0].outcome else {
      return XCTFail("Expected unavailable credential")
    }
    XCTAssertTrue(reason.contains("fireconnect login"))
  }

  func testEmptyAccountDiscoveryIsUnavailable() async throws {
    let adapter = FireworksAdapter(
      credential: { Secret("fw_secret") },
      accounts: { _ in [] },
      costs: { _, _, _, _ in
        XCTFail("Costs must not run")
        return fireworksResult(amount: 0)
      },
      now: { juneDate() }
    )

    let result = try await adapter.fetch(window: juneWindow())

    XCTAssertTrue(result.records.isEmpty)
    XCTAssertTrue(result.refreshedSourceIDs.isEmpty)
    XCTAssertEqual(
      result.attempts.map(\.strategyID),
      [
        "fireworks-credential", "fireworks-account-discovery",
      ])
    guard case .unavailable = result.attempts[1].outcome else {
      return XCTFail("Expected unavailable account discovery")
    }
  }

  func testOneAccountFailurePreservesSuccessfulRecordsAndCacheSource() async throws {
    let adapter = FireworksAdapter(
      credential: { Secret("fw_secret") },
      accounts: { _ in
        [
          FireworksAccount(resourceName: "accounts/good", id: "good"),
          FireworksAccount(resourceName: "accounts/bad", id: "bad"),
        ]
      },
      costs: { account, _, _, _ in
        if account.id == "bad" {
          throw ProviderClientError.httpStatus(500)
        }
        return fireworksResult(amount: 4)
      },
      fingerprinter: AccountFingerprinter(key: Data(repeating: 3, count: 32)),
      now: { juneDate() }
    )

    let result = try await adapter.fetch(window: juneWindow())

    XCTAssertEqual(result.records.map(\.amount), [Money(4)])
    XCTAssertEqual(result.refreshedSourceIDs, Set(result.records.map(\.sourceID)))
    XCTAssertEqual(result.refreshedSourceIDs.count, 1)
    guard case .partial(let message) = result.coverage else {
      return XCTFail("Expected partial coverage")
    }
    XCTAssertEqual(result.sourceAuthority, .refreshedSources)
    XCTAssertTrue(message.contains("unavailable"))
  }

  func testEveryAccountFailureReportsFailedRefreshWithoutAuthorizingCachePruning()
    async throws
  {
    let adapter = FireworksAdapter(
      credential: { Secret("fw_secret") },
      accounts: { _ in
        [
          FireworksAccount(resourceName: "accounts/first", id: "first"),
          FireworksAccount(resourceName: "accounts/second", id: "second"),
        ]
      },
      costs: { _, _, _, _ in
        throw ProviderClientError.httpStatus(500)
      },
      fingerprinter: AccountFingerprinter(key: Data(repeating: 9, count: 32)),
      now: { juneDate() }
    )

    let result = try await adapter.fetch(window: juneWindow())

    XCTAssertTrue(result.records.isEmpty)
    XCTAssertTrue(result.refreshedSourceIDs.isEmpty)
    XCTAssertEqual(result.coverage, .complete)
    XCTAssertEqual(result.sourceAuthority, .refreshedSources)
    let failureMessages = result.attempts.compactMap { attempt -> String? in
      guard case .failed(let message) = attempt.outcome else {
        return nil
      }
      return message
    }
    XCTAssertEqual(
      failureMessages,
      [
        "Fireworks request failed (HTTP 500).",
        "Fireworks request failed (HTTP 500).",
      ]
    )
  }

  func testZeroCostSuccessRefreshesAccountSourceWithoutInventingRecord() async throws {
    let adapter = makeAdapter { _, _, _, _ in
      FireworksCostResult(rows: [], subtotal: 0)
    }

    let result = try await adapter.fetch(window: juneWindow())

    XCTAssertTrue(result.records.isEmpty)
    XCTAssertEqual(result.refreshedSourceIDs.count, 1)
    XCTAssertEqual(result.coverage, .complete)
    XCTAssertEqual(result.sourceAuthority, .allProviderSources)
    XCTAssertEqual(result.attempts.last?.outcome, .succeeded(recordCount: 0))
  }

  func testSubtotalGreaterThanRowsAddsUnknownReconciliationRecord() async throws {
    let adapter = makeAdapter { _, _, _, _ in
      fireworksResult(amount: 2, subtotal: 5, model: "deepseek-v3")
    }

    let result = try await adapter.fetch(window: juneWindow())

    XCTAssertEqual(result.records.map(\.amount), [Money(2), Money(3)])
    XCTAssertEqual(result.records.map(\.model), ["deepseek-v3", "unknown"])
    XCTAssertEqual(result.records.last?.intervalStart, juneWindow().start)
    XCTAssertEqual(result.records.last?.intervalEnd, juneWindow().end)
    XCTAssertEqual(
      result.records.map(\.amount).reduce(.zero, +),
      Money(5)
    )
  }

  func testSubtotalRemainderHasDistinctStableIdentityFromMatchingUnknownRow() async throws {
    let adapter = makeAdapter { _, window, _, _ in
      FireworksCostResult(
        rows: [
          FireworksCostRow(
            start: window.start,
            end: window.end,
            model: "unknown",
            amount: 1
          )
        ],
        subtotal: 2
      )
    }

    let result = try await adapter.fetch(window: juneWindow())

    XCTAssertEqual(result.records.map(\.amount), [Money(1), Money(1)])
    XCTAssertEqual(Set(result.records.map(\.id)).count, 2)
    XCTAssertEqual(Set(result.records.map(\.observationID)).count, 2)
  }

  func testRowsCanonicalizingToSameIdentityAreSummedBeforeRecordCreation() async throws {
    let rawModels = [
      "accounts/private-owner/invalid/resource",
      "accounts/private-project/models",
    ]
    let adapter = makeAdapter { _, window, _, _ in
      FireworksCostResult(
        rows: [
          FireworksCostRow(
            start: window.start,
            end: window.start.addingTimeInterval(86_400),
            model: rawModels[0],
            amount: 1.25
          ),
          FireworksCostRow(
            start: window.start,
            end: window.start.addingTimeInterval(86_400),
            model: rawModels[1],
            amount: 2.75
          ),
        ],
        subtotal: 4
      )
    }

    let result = try await adapter.fetch(window: juneWindow())

    XCTAssertEqual(result.records.count, 1)
    XCTAssertEqual(result.records.first?.model, "unknown")
    XCTAssertEqual(result.records.first?.amount, Money(4))
    XCTAssertEqual(result.coverage, .complete)
    XCTAssertEqual(result.attempts.last?.outcome, .succeeded(recordCount: 1))
    try assertNoFireworksIdentity(in: result, rawValues: rawModels)
  }

  func testRowsGreaterThanSubtotalFailOnlyThatAccount() async throws {
    let adapter = makeAdapter { _, _, _, _ in
      fireworksResult(amount: 5, subtotal: 2)
    }

    let result = try await adapter.fetch(window: juneWindow())

    XCTAssertTrue(result.records.isEmpty)
    XCTAssertTrue(result.refreshedSourceIDs.isEmpty)
    XCTAssertEqual(result.coverage, .complete)
    XCTAssertEqual(result.sourceAuthority, .refreshedSources)
    guard case .failed = result.attempts.last?.outcome else {
      return XCTFail("Expected failed cost attempt")
    }
  }

  func testOnlyUnauthorizedStatusesTriggerPersonalFallback() async throws {
    for status in [401, 403, 429, 500] {
      let scopes = FireworksScopeRecorder()
      let adapter = makeAdapter { _, _, scope, _ in
        scopes.append(scope)
        throw ProviderClientError.httpStatus(status)
      }

      _ = try await adapter.fetch(window: juneWindow())

      XCTAssertEqual(
        scopes.values,
        status == 401 || status == 403 ? [.account, .personal] : [.account],
        "Unexpected fallback behavior for HTTP \(status)"
      )
    }
  }

  func testNonAuthorizationAccountFailureDoesNotUsePersonalFallback() async throws {
    for status in [429, 500] {
      for hasSuccessfulSibling in [true, false] {
        let scopes = FireworksScopeRecorder()
        let accounts = [
          FireworksAccount(resourceName: "accounts/bad", id: "bad"),
          FireworksAccount(resourceName: "accounts/good", id: "good"),
        ]
        let adapter = FireworksAdapter(
          credential: { Secret("fw_secret") },
          accounts: { _ in
            hasSuccessfulSibling ? accounts : [accounts[0]]
          },
          costs: { account, _, scope, _ in
            scopes.append(scope)
            if account.id == "bad" {
              throw ProviderClientError.httpStatus(status)
            }
            return fireworksResult(amount: 2)
          },
          fingerprinter: AccountFingerprinter(key: Data(repeating: 3, count: 32)),
          now: { juneDate() }
        )

        let result = try await adapter.fetch(window: juneWindow())

        XCTAssertEqual(
          scopes.values,
          hasSuccessfulSibling ? [.account, .account] : [.account],
          "Unexpected fallback for HTTP \(status)"
        )
        if hasSuccessfulSibling {
          XCTAssertEqual(result.records.map(\.amount), [Money(2)])
          guard case .partial = result.coverage else {
            return XCTFail("Expected partial coverage for HTTP \(status)")
          }
        } else {
          XCTAssertTrue(result.records.isEmpty)
          XCTAssertEqual(result.coverage, .complete)
        }
        XCTAssertEqual(result.sourceAuthority, .refreshedSources)
      }
    }
  }

  func testPersonalFallbackFailureRemainsFailedAccount() async throws {
    for hasSuccessfulSibling in [true, false] {
      let scopes = FireworksScopeRecorder()
      let accounts = [
        FireworksAccount(resourceName: "accounts/bad", id: "bad"),
        FireworksAccount(resourceName: "accounts/good", id: "good"),
      ]
      let adapter = FireworksAdapter(
        credential: { Secret("fw_secret") },
        accounts: { _ in
          hasSuccessfulSibling ? accounts : [accounts[0]]
        },
        costs: { account, _, scope, _ in
          scopes.append(scope)
          if account.id == "bad" {
            if scope == .account {
              throw ProviderClientError.httpStatus(403)
            }
            throw ProviderClientError.httpStatus(500)
          }
          return fireworksResult(amount: 2)
        },
        fingerprinter: AccountFingerprinter(key: Data(repeating: 3, count: 32)),
        now: { juneDate() }
      )

      let result = try await adapter.fetch(window: juneWindow())

      XCTAssertEqual(
        scopes.values,
        hasSuccessfulSibling ? [.account, .personal, .account] : [.account, .personal]
      )
      let personalAttempt = try XCTUnwrap(
        result.attempts.last { $0.strategyID == "fireworks-self-costs" }
      )
      guard case .failed(let message) = personalAttempt.outcome else {
        return XCTFail("Expected failed personal-scope attempt")
      }
      XCTAssertEqual(message, "Fireworks request failed (HTTP 500).")
      if hasSuccessfulSibling {
        XCTAssertEqual(result.records.map(\.amount), [Money(2)])
        guard case .partial = result.coverage else {
          return XCTFail("Expected partial coverage")
        }
      } else {
        XCTAssertTrue(result.records.isEmpty)
        XCTAssertEqual(result.coverage, .complete)
      }
      XCTAssertEqual(result.sourceAuthority, .refreshedSources)
    }
  }

  func testFPKAuthorizationFailureUsesRedactedStandardKeyGuidance() async throws {
    let adapter = makeAdapter(
      credential: Secret("fpk_super_secret_value"),
      account: FireworksAccount(
        resourceName: "accounts/raw-private-account",
        id: "raw-private-account"
      )
    ) { _, _, _, _ in
      throw ProviderClientError.httpStatus(403)
    }

    let result = try await adapter.fetch(window: juneWindow())

    let diagnostic = String(describing: result.attempts)
    XCTAssertTrue(diagnostic.localizedCaseInsensitiveContains("standard"))
    XCTAssertFalse(diagnostic.contains("fpk_super_secret_value"))
    XCTAssertFalse(diagnostic.contains("raw-private-account"))
  }

  func testAccountFailureRedactsCredentialAndRawAccountIdentifiers() async throws {
    let adapter = makeAdapter(
      credential: Secret("fpk_private_secret"),
      account: FireworksAccount(resourceName: "accounts/raw-customer", id: "raw-customer")
    ) { _, _, _, _ in
      throw NSError(
        domain: "accounts/raw-customer Authorization=fpk_private_secret",
        code: 1
      )
    }

    let result = try await adapter.fetch(window: juneWindow())

    guard case .failed(let message) = result.attempts.last?.outcome else {
      return XCTFail("Expected failed account attempt")
    }
    XCTAssertFalse(message.contains("raw-customer"))
    XCTAssertFalse(message.contains("fpk_private_secret"))
  }

  func testCancellationIsRethrownWithoutMarkingAccountFailed() async {
    let adapter = makeAdapter { _, _, _, _ in
      throw CancellationError()
    }

    do {
      _ = try await adapter.fetch(window: juneWindow())
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      XCTAssertTrue(true)
    } catch {
      XCTFail("Expected CancellationError, got \(error)")
    }
  }

  func testCancellationMarkedBySuccessfulClockStopsBeforeCredentialDiscovery() async {
    let credentialInvocations = LockedInt()
    let adapter = FireworksAdapter(
      credential: {
        credentialInvocations.increment()
        return Secret("fw_secret")
      },
      accounts: { _ in [] },
      costs: { _, _, _, _ in fireworksResult(amount: 0) },
      now: {
        withUnsafeCurrentTask { $0?.cancel() }
        return juneDate()
      }
    )

    await assertCancellation(from: adapter, seam: "successful clock")
    XCTAssertEqual(credentialInvocations.value, 0)
  }

  func testCancellationMarkedBySuccessfulCostDependencyIsRethrown() async {
    let adapter = makeAdapter { _, _, _, _ in
      withUnsafeCurrentTask { $0?.cancel() }
      return fireworksResult(amount: 1)
    }
    let task = Task {
      try await adapter.fetch(window: juneWindow())
    }

    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      XCTAssertTrue(true)
    } catch {
      XCTFail("Expected CancellationError, got \(error)")
    }
  }

  func testCancelledCredentialErrorIsRethrownAsCancellation() async {
    let adapter = FireworksAdapter(
      credential: {
        withUnsafeCurrentTask { $0?.cancel() }
        throw URLError(.cancelled)
      },
      accounts: { _ in [] },
      costs: { _, _, _, _ in fireworksResult(amount: 0) },
      now: { juneDate() }
    )

    await assertCancellation(from: adapter, seam: "credential")
  }

  func testCancelledDiscoveryErrorIsRethrownAsCancellation() async {
    let adapter = FireworksAdapter(
      credential: { Secret("fw_secret") },
      accounts: { _ in
        withUnsafeCurrentTask { $0?.cancel() }
        throw NSError(domain: "discovery stopped", code: 1)
      },
      costs: { _, _, _, _ in fireworksResult(amount: 0) },
      now: { juneDate() }
    )

    await assertCancellation(from: adapter, seam: "discovery")
  }

  func testCancelledAccountQueryErrorIsRethrownAsCancellation() async {
    let adapter = makeAdapter { _, _, _, _ in
      withUnsafeCurrentTask { $0?.cancel() }
      throw URLError(.cancelled)
    }

    await assertCancellation(from: adapter, seam: "account query")
  }

  func testCancelledSelfFallbackErrorIsRethrownAsCancellation() async {
    let adapter = makeAdapter { _, _, scope, _ in
      if scope == .account {
        throw ProviderClientError.httpStatus(403)
      }
      withUnsafeCurrentTask { $0?.cancel() }
      throw NSError(domain: "self fallback stopped", code: 1)
    }

    await assertCancellation(from: adapter, seam: "SELF fallback")
  }

  func testCancelledFingerprintErrorIsRethrownAsCancellation() async {
    let adapter = FireworksAdapter(
      credential: { Secret("fw_secret") },
      accounts: { _ in
        [FireworksAccount(resourceName: "accounts/personal", id: "personal")]
      },
      costs: { _, _, _, _ in fireworksResult(amount: 0) },
      fingerprinter: AccountFingerprinter { _, _ in
        withUnsafeCurrentTask { $0?.cancel() }
        throw NSError(domain: "fingerprint stopped", code: 1)
      },
      now: { juneDate() }
    )

    await assertCancellation(from: adapter, seam: "fingerprint")
  }

  func testCancellationMarkedBySuccessfulFingerprintStopsBeforeCostQuery() async {
    let costInvocations = LockedInt()
    let adapter = FireworksAdapter(
      credential: { Secret("fw_secret") },
      accounts: { _ in
        [FireworksAccount(resourceName: "accounts/personal", id: "personal")]
      },
      costs: { _, _, _, _ in
        costInvocations.increment()
        return fireworksResult(amount: 1)
      },
      fingerprinter: AccountFingerprinter { _, _ in
        withUnsafeCurrentTask { $0?.cancel() }
        return "fingerprint"
      },
      now: { juneDate() }
    )

    await assertCancellation(from: adapter, seam: "successful fingerprint")
    XCTAssertEqual(costInvocations.value, 0)
  }

  private func assertCancellation(
    from adapter: FireworksAdapter,
    seam: String
  ) async {
    let task = Task {
      try await adapter.fetch(window: juneWindow())
    }
    do {
      _ = try await task.value
      XCTFail("Expected cancellation from \(seam)")
    } catch is CancellationError {
      XCTAssertTrue(true)
    } catch {
      XCTFail("Expected CancellationError from \(seam), got \(error)")
    }
  }

  private func assertNoFireworksIdentity(
    in result: ProviderFetchResult,
    rawValues: [String],
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let persistedRecords = try JSONEncoder().encode(result.records)
    let output = [
      String(decoding: persistedRecords, as: UTF8.self),
      String(describing: result.attempts),
      String(describing: result.coverage),
      String(describing: result.refreshedSourceIDs),
    ].joined(separator: "\n")
    for rawValue in rawValues {
      XCTAssertFalse(
        output.contains(rawValue),
        "Leaked raw Fireworks identity: \(rawValue)",
        file: file,
        line: line
      )
    }
  }

  private func makeAdapter(
    credential: Secret = Secret("fw_secret"),
    account: FireworksAccount = FireworksAccount(
      resourceName: "accounts/personal",
      id: "personal"
    ),
    costs:
      @escaping @Sendable (
        FireworksAccount,
        MonthWindow,
        FireworksCostScope,
        Secret
      ) async throws -> FireworksCostResult
  ) -> FireworksAdapter {
    FireworksAdapter(
      credential: { credential },
      accounts: { _ in [account] },
      costs: costs,
      fingerprinter: AccountFingerprinter(key: Data(repeating: 9, count: 32)),
      now: { juneDate() }
    )
  }

}

private final class FireworksScopeRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [FireworksCostScope] = []

  var values: [FireworksCostScope] {
    lock.withLock { stored }
  }

  func append(_ scope: FireworksCostScope) {
    lock.withLock { stored.append(scope) }
  }
}

private func fireworksResult(
  amount: Decimal,
  subtotal: Decimal? = nil,
  model: String = "kimi-k2"
) -> FireworksCostResult {
  FireworksCostResult(
    rows: amount == 0
      ? []
      : [
        FireworksCostRow(
          start: juneWindow().start,
          end: juneWindow().start.addingTimeInterval(86_400),
          model: model,
          amount: amount
        )
      ],
    subtotal: subtotal ?? amount
  )
}
