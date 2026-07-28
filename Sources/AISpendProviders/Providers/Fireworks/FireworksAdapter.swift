import AISpendCore
import Foundation

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

  init(
    credential: @escaping @Sendable () throws -> Secret?,
    accounts: @escaping @Sendable (Secret) async throws -> [FireworksAccount],
    costs:
      @escaping @Sendable (
        FireworksAccount,
        MonthWindow,
        FireworksCostScope,
        Secret
      ) async throws -> FireworksCostResult,
    fingerprinter: AccountFingerprinter = .production,
    now: @escaping @Sendable () -> Date,
    redactor: Redactor = Redactor()
  ) {
    self.credential = credential
    self.accounts = accounts
    self.costs = costs
    self.fingerprinter = fingerprinter
    self.now = now
    self.redactor = redactor
  }

  public init(
    credentialHost: CredentialHost = CredentialHost(),
    httpClient: HTTPClient = HTTPClient(),
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    let client = FireworksCostClient(httpClient: httpClient)
    self.init(
      credential: { try FireworksCredential.resolve(from: credentialHost) },
      accounts: client.accounts,
      costs: client.costs,
      fingerprinter: .production,
      now: now
    )
  }

  public func fetch(window: MonthWindow) async throws -> ProviderFetchResult {
    try Task.checkCancellation()
    let fetchedAt = now()
    var attempts: [SourceAttempt] = []

    let resolvedCredential: Secret
    do {
      let value = try credential()
      try Task.checkCancellation()
      guard let value else {
        attempts.append(
          SourceAttempt(
            strategyID: "fireworks-credential",
            outcome: .unavailable(
              reason: "No Fireworks credential. Run `fireconnect login` to connect."
            )
          )
        )
        return emptyResult(attempts: attempts, fetchedAt: fetchedAt)
      }
      resolvedCredential = value
      attempts.append(
        SourceAttempt(
          strategyID: "fireworks-credential",
          outcome: .succeeded(recordCount: 0)
        )
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      try Task.checkCancellation()
      attempts.append(
        SourceAttempt(
          strategyID: "fireworks-credential",
          outcome: .failed(redactedMessage: safeMessage(for: error))
        )
      )
      return emptyResult(attempts: attempts, fetchedAt: fetchedAt)
    }

    let discoveredAccounts: [FireworksAccount]
    do {
      try Task.checkCancellation()
      discoveredAccounts = try await accounts(resolvedCredential)
      try Task.checkCancellation()
      guard !discoveredAccounts.isEmpty else {
        attempts.append(
          SourceAttempt(
            strategyID: "fireworks-account-discovery",
            outcome: .unavailable(reason: "No accessible Fireworks accounts.")
          )
        )
        return emptyResult(attempts: attempts, fetchedAt: fetchedAt)
      }
      attempts.append(
        SourceAttempt(
          strategyID: "fireworks-account-discovery",
          outcome: .succeeded(recordCount: discoveredAccounts.count)
        )
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      try Task.checkCancellation()
      attempts.append(
        SourceAttempt(
          strategyID: "fireworks-account-discovery",
          outcome: .failed(
            redactedMessage: safeMessage(for: error, credential: resolvedCredential)
          )
        )
      )
      return emptyResult(attempts: attempts, fetchedAt: fetchedAt)
    }

    var records: [SpendRecord] = []
    var refreshedSourceIDs = Set<String>()
    var usedPersonalScope = false
    var failedAccount = false

    for account in discoveredAccounts {
      try Task.checkCancellation()
      do {
        let fingerprint = try fingerprinter.fingerprint(
          identity: resolvedCredential,
          namespace: "fireworks-account:\(account.resourceName)"
        )
        let sourceID = "fireworks-usage-costs:\(fingerprint)"
        let scope: FireworksCostScope
        let result: FireworksCostResult

        do {
          result = try await costs(account, window, .account, resolvedCredential)
          scope = .account
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          try Task.checkCancellation()
          attempts.append(
            SourceAttempt(
              strategyID: "fireworks-account-costs",
              outcome: .failed(
                redactedMessage: safeMessage(
                  for: error,
                  credential: resolvedCredential,
                  accounts: discoveredAccounts
                )
              )
            )
          )
          guard Self.isAuthorizationFailure(error) else {
            failedAccount = true
            continue
          }

          do {
            try Task.checkCancellation()
            result = try await costs(account, window, .personal, resolvedCredential)
            scope = .personal
            usedPersonalScope = true
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            try Task.checkCancellation()
            attempts.append(
              SourceAttempt(
                strategyID: "fireworks-self-costs",
                outcome: .failed(
                  redactedMessage: safeMessage(
                    for: error,
                    credential: resolvedCredential,
                    accounts: discoveredAccounts
                  )
                )
              )
            )
            failedAccount = true
            continue
          }
        }

        do {
          try Task.checkCancellation()
          let normalized = try normalize(
            result,
            accounts: discoveredAccounts,
            accountFingerprint: fingerprint,
            sourceID: sourceID,
            scope: scope,
            window: window,
            fetchedAt: fetchedAt
          )
          records.append(contentsOf: normalized)
          refreshedSourceIDs.insert(sourceID)
          attempts.append(
            SourceAttempt(
              strategyID: scope == .account
                ? "fireworks-account-costs"
                : "fireworks-self-costs",
              outcome: .succeeded(recordCount: normalized.count)
            )
          )
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          try Task.checkCancellation()
          attempts.append(
            SourceAttempt(
              strategyID: scope == .account
                ? "fireworks-account-costs"
                : "fireworks-self-costs",
              outcome: .failed(
                redactedMessage: safeMessage(
                  for: error,
                  credential: resolvedCredential,
                  accounts: discoveredAccounts
                )
              )
            )
          )
          failedAccount = true
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        try Task.checkCancellation()
        attempts.append(
          SourceAttempt(
            strategyID: "fireworks-account-costs",
            outcome: .failed(
              redactedMessage: safeMessage(
                for: error,
                credential: resolvedCredential,
                accounts: discoveredAccounts
              )
            )
          )
        )
        failedAccount = true
      }
    }

    let coverage: ProviderDataCoverage
    if failedAccount {
      coverage = .partial(message: "Some Fireworks account spend is unavailable.")
    } else if usedPersonalScope {
      coverage = .partial(
        message: "Only authenticated-user Fireworks spend is available for at least one account."
      )
    } else {
      coverage = .complete
    }

    return ProviderFetchResult(
      provider: provider,
      records: records,
      attempts: attempts,
      refreshedSourceIDs: refreshedSourceIDs,
      fetchedAt: fetchedAt,
      coverage: coverage
    )
  }

  private func normalize(
    _ result: FireworksCostResult,
    accounts: [FireworksAccount],
    accountFingerprint: String,
    sourceID: String,
    scope: FireworksCostScope,
    window: MonthWindow,
    fetchedAt: Date
  ) throws -> [SpendRecord] {
    let rowTotal = result.rows.reduce(Decimal.zero) { $0 + $1.amount }
    guard rowTotal <= result.subtotal else {
      throw FireworksAdapterError.rowsExceedSubtotal
    }

    var normalized = try result.rows.map {
      let model = Self.privacySafeModel($0.model, accounts: accounts)
      return try record(
        start: $0.start,
        end: $0.end,
        model: model,
        amount: $0.amount,
        accountFingerprint: accountFingerprint,
        sourceID: sourceID,
        scope: scope,
        fetchedAt: fetchedAt,
        identifierKind: "grouped-row"
      )
    }

    let remainder = result.subtotal - rowTotal
    if remainder > 0 {
      normalized.append(
        try record(
          start: window.start,
          end: window.end,
          model: "unknown",
          amount: remainder,
          accountFingerprint: accountFingerprint,
          sourceID: sourceID,
          scope: scope,
          fetchedAt: fetchedAt,
          identifierKind: "subtotal-remainder"
        )
      )
    }
    return normalized
  }

  private func record(
    start: Date,
    end: Date,
    model: String,
    amount: Decimal,
    accountFingerprint: String,
    sourceID: String,
    scope: FireworksCostScope,
    fetchedAt: Date,
    identifierKind: String
  ) throws -> SpendRecord {
    let observationID = stableIdentifier([
      "fireworks-cost",
      accountFingerprint,
      String(start.timeIntervalSince1970),
      String(end.timeIntervalSince1970),
      model,
      scope.rawValue,
      identifierKind,
    ])
    return try SpendRecord(
      id: observationID,
      provider: .fireworks,
      accountFingerprint: accountFingerprint,
      model: model,
      intervalStart: start,
      intervalEnd: end,
      amount: Money(amount),
      quality: .actual,
      sourceID: sourceID,
      observationID: observationID,
      fetchedAt: fetchedAt,
      estimate: nil
    )
  }

  private func emptyResult(
    attempts: [SourceAttempt],
    fetchedAt: Date
  ) -> ProviderFetchResult {
    ProviderFetchResult(
      provider: provider,
      records: [],
      attempts: attempts,
      refreshedSourceIDs: [],
      fetchedAt: fetchedAt
    )
  }

  private static func isAuthorizationFailure(_ error: Error) -> Bool {
    guard case ProviderClientError.httpStatus(let status) = error else {
      return false
    }
    return status == 401 || status == 403
  }

  private static func privacySafeModel(
    _ model: String,
    accounts: [FireworksAccount]
  ) -> String {
    let components = model.split(separator: "/", omittingEmptySubsequences: false)
    let label: String
    if components.first == "accounts" {
      guard
        let modelsIndex = components.firstIndex(of: "models"),
        modelsIndex > components.startIndex,
        components.index(after: modelsIndex) < components.endIndex
      else {
        return "unknown"
      }
      let modelComponents = components[components.index(after: modelsIndex)...]
      guard !modelComponents.contains(where: \.isEmpty) else {
        return "unknown"
      }
      label = modelComponents.joined(separator: "/")
    } else {
      label = model
    }
    return redactAccountIdentities(in: label, accounts: accounts)
  }

  private static func redactAccountIdentities(
    in value: String,
    accounts: [FireworksAccount]
  ) -> String {
    let identities = Set(
      accounts.flatMap { [$0.resourceName, $0.id] }.filter { !$0.isEmpty }
    ).sorted {
      if $0.count == $1.count {
        return $0 < $1
      }
      return $0.count > $1.count
    }
    return identities.reduce(value) {
      $0.replacingOccurrences(of: $1, with: "[account]")
    }
  }

  private func safeMessage(
    for error: Error,
    credential: Secret? = nil,
    accounts: [FireworksAccount] = []
  ) -> String {
    let message: String
    switch error {
    case ProviderClientError.httpStatus(let status) where status == 401 || status == 403:
      if credential?.withValue({ $0.hasPrefix("fpk_") }) == true {
        message = "Authorization failed. Use a standard Fireworks API key for usage-cost access."
      } else {
        message = "Authorization failed (HTTP \(status))."
      }
    case ProviderClientError.httpStatus(let status):
      message = "Fireworks request failed (HTTP \(status))."
    case ProviderClientError.unsupportedCurrency:
      message = "Fireworks returned an unsupported currency."
    case ProviderClientError.invalidResponse:
      message = "Fireworks returned an invalid response."
    case FireworksAdapterError.rowsExceedSubtotal:
      message = "Fireworks grouped costs exceed the query subtotal."
    default:
      message = error.localizedDescription
    }

    var sanitized = redactor.redact(message)
    if let credential {
      sanitized = credential.withValue {
        sanitized.replacingOccurrences(of: $0, with: "[REDACTED]")
      }
    }
    return Self.redactAccountIdentities(in: sanitized, accounts: accounts)
  }
}

private enum FireworksAdapterError: Error {
  case rowsExceedSubtotal
}
