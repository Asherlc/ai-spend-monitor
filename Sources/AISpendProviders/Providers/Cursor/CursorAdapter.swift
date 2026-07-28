import AISpendCore
import Foundation

public struct CursorAdapter: ProviderAdapter {
  public let provider = ProviderID.cursor

  private let adminCredential: @Sendable () throws -> Secret?
  private let appSessionAvailable: @Sendable () throws -> Bool
  private let csvUsage: (@Sendable (MonthWindow, Date) throws -> CursorCSVScanResult?)?
  private let browserDiscoveryEnabled: @Sendable () -> Bool
  private let usage: @Sendable (MonthWindow, Secret) async throws -> CursorUsageResult
  private let fingerprinter: AccountFingerprinter
  private let calendar: Calendar
  private let now: @Sendable () -> Date
  private let redactor: Redactor

  init(
    adminCredential: @escaping @Sendable () throws -> Secret?,
    appSessionAvailable: @escaping @Sendable () throws -> Bool,
    csvUsage: (@Sendable (MonthWindow, Date) throws -> CursorCSVScanResult?)? = nil,
    browserDiscoveryEnabled: @escaping @Sendable () -> Bool = { true },
    usage: @escaping @Sendable (MonthWindow, Secret) async throws -> CursorUsageResult,
    fingerprinter: AccountFingerprinter = .production,
    calendar: Calendar = .current,
    now: @escaping @Sendable () -> Date,
    redactor: Redactor = Redactor()
  ) {
    self.adminCredential = adminCredential
    self.appSessionAvailable = appSessionAvailable
    self.csvUsage = csvUsage
    self.browserDiscoveryEnabled = browserDiscoveryEnabled
    self.usage = usage
    self.fingerprinter = fingerprinter
    self.calendar = calendar
    self.now = now
    self.redactor = redactor
  }

  public init(
    credentialHost: CredentialHost = CredentialHost(),
    stateReader: CursorStateReader = CursorStateReader(),
    browserDiscovery: BrowserDiscoveryPreference = BrowserDiscoveryPreference(),
    httpClient: HTTPClient = HTTPClient(),
    calendar: Calendar = .current,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    let client = CursorUsageClient(httpClient: httpClient)
    let csvScanner = CursorCSVScanner(calendar: calendar)
    self.init(
      adminCredential: {
        try credentialHost.environmentSecret(named: "CURSOR_ADMIN_API_KEY")
      },
      appSessionAvailable: {
        let state = try stateReader.read()
        return state.accessToken != nil && state.teamID != nil
      },
      csvUsage: { window, fetchedAt in
        try csvScanner.scan(window: window, fetchedAt: fetchedAt)
      },
      browserDiscoveryEnabled: { browserDiscovery.isEnabled },
      usage: { window, adminKey in
        try await client.fetch(window: window, adminKey: adminKey)
      },
      fingerprinter: .production,
      calendar: calendar,
      now: now
    )
  }

  public func fetch(window: MonthWindow) async throws -> ProviderFetchResult {
    try Task.checkCancellation()
    let fetchedAt = now()
    guard try MonthWindow.current(containing: fetchedAt, calendar: calendar) == window else {
      return ProviderFetchResult(
        provider: provider,
        records: [],
        attempts: [
          .init(
            strategyID: "cursor-admin-actual",
            outcome: .unavailable(
              reason: "Cursor team spend is available only for the current calendar month."
            )
          ),
          try appAttempt(),
        ],
        refreshedSourceIDs: [],
        fetchedAt: fetchedAt
      )
    }

    var records: [SpendRecord] = []
    var attempts: [SourceAttempt] = []
    var refreshedSourceIDs = Set<String>()
    var hasActualSource = false
    do {
      if let adminKey = try adminCredential() {
        let result = try await usage(window, adminKey)
        let accountFingerprint = try fingerprinter.fingerprint(
          identity: adminKey,
          namespace: "cursor-team"
        )
        let normalized = try normalize(
          result,
          window: window,
          fetchedAt: fetchedAt,
          accountFingerprint: accountFingerprint
        )
        records = normalized.records
        refreshedSourceIDs.insert("cursor-team-spend")
        hasActualSource = true
        attempts.append(
          .init(
            strategyID: "cursor-admin-actual",
            outcome: .succeeded(recordCount: records.count)
          )
        )
        attempts.append(contentsOf: normalized.diagnostics)
      } else {
        attempts.append(
          .init(
            strategyID: "cursor-admin-actual",
            outcome: .unavailable(reason: "No Cursor admin credential.")
          )
        )
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      attempts.append(
        .init(
          strategyID: "cursor-admin-actual",
          outcome: .failed(redactedMessage: message(for: error))
        )
      )
    }

    if !hasActualSource, let csvUsage {
      do {
        if let result = try csvUsage(window, fetchedAt) {
          records = result.records
          refreshedSourceIDs.insert(result.sourceID)
          attempts.append(
            .init(
              strategyID: "cursor-dashboard-export",
              outcome: .succeeded(recordCount: records.count)
            )
          )
        } else {
          attempts.append(
            .init(
              strategyID: "cursor-dashboard-export",
              outcome: .unavailable(
                reason: "No Cursor dashboard usage export in Downloads."
              )
            )
          )
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        attempts.append(
          .init(
            strategyID: "cursor-dashboard-export",
            outcome: .failed(redactedMessage: message(for: error))
          )
        )
      }
    }

    attempts.append(try appAttempt())
    return ProviderFetchResult(
      provider: provider,
      records: records,
      attempts: attempts,
      refreshedSourceIDs: refreshedSourceIDs,
      fetchedAt: fetchedAt
    )
  }

  private func normalize(
    _ result: CursorUsageResult,
    window: MonthWindow,
    fetchedAt: Date,
    accountFingerprint: String
  ) throws -> (records: [SpendRecord], diagnostics: [SourceAttempt]) {
    let modelTotal = result.modelCents.values.reduce(0, +)
    let allocations: [String: Decimal]
    let diagnostics: [SourceAttempt]
    if modelTotal > result.authoritativeCents {
      allocations = ["unknown": result.authoritativeCents]
      diagnostics = [
        .init(
          strategyID: "cursor-attribution",
          outcome: .failed(
            redactedMessage:
              "Cursor usage schema mismatch: model attribution exceeds authoritative spend."
          )
        )
      ]
    } else {
      var attributed = result.modelCents
      if modelTotal < result.authoritativeCents {
        attributed["unknown", default: 0] += result.authoritativeCents - modelTotal
      }
      allocations = attributed
      diagnostics = []
    }

    let records = try allocations.sorted(by: { $0.key < $1.key }).map { allocation in
      let observationID = stableIdentifier([
        "cursor-spend",
        accountFingerprint,
        String(window.start.timeIntervalSince1970),
        String(window.end.timeIntervalSince1970),
        allocation.key,
      ])
      return try SpendRecord(
        id: observationID,
        provider: .cursor,
        accountFingerprint: accountFingerprint,
        model: allocation.key,
        intervalStart: window.start,
        intervalEnd: window.end,
        amount: Money(allocation.value / 100),
        quality: .actual,
        sourceID: "cursor-team-spend",
        observationID: observationID,
        fetchedAt: fetchedAt,
        estimate: nil
      )
    }
    return (records, diagnostics)
  }

  private func appAttempt() throws -> SourceAttempt {
    try Task.checkCancellation()
    guard browserDiscoveryEnabled() else {
      return .init(
        strategyID: "cursor-app-session",
        outcome: .unavailable(
          reason: "Browser and app-session discovery is disabled."
        )
      )
    }
    do {
      if try appSessionAvailable() {
        return .init(
          strategyID: "cursor-app-session",
          outcome: .unavailable(
            reason: "No documented Cursor application-session billing endpoint."
          )
        )
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch SourceHostError.sourceUnavailable {
      // A missing application database is the same as no authenticated session.
    } catch {
      return .init(
        strategyID: "cursor-app-session",
        outcome: .failed(redactedMessage: redactor.redact(error.localizedDescription))
      )
    }
    return .init(
      strategyID: "cursor-app-session",
      outcome: .unavailable(reason: "No authenticated Cursor application session.")
    )
  }

  private func message(for error: Error) -> String {
    if case ProviderClientError.httpStatus(let status) = error,
      status == 401 || status == 403
    {
      return "Authorization failed (HTTP \(status))."
    }
    return redactor.redact(error.localizedDescription)
  }
}
