import AISpendCore
import Foundation

@MainActor
final class BudgetAlertRuntime {
  typealias Delivery =
    @MainActor @Sendable (BudgetAlertDecision) async throws ->
    StoredBudgetAlertState

  private let repository: any LedgerRepository
  private let engine: BudgetAlertEngine
  private let deliver: Delivery
  private let sanitizer: DiagnosticSanitizer
  private var isProcessing = false
  private var processingWaiters: [CheckedContinuation<Void, Never>] = []

  init(
    repository: any LedgerRepository,
    engine: BudgetAlertEngine = BudgetAlertEngine(),
    deliver: @escaping Delivery
  ) {
    self.repository = repository
    self.engine = engine
    self.deliver = deliver
    sanitizer = DiagnosticSanitizer()
  }

  func process(snapshot: RefreshSnapshot) async -> RefreshSnapshot {
    guard await acquireProcessingSlot() else {
      return snapshot
    }
    defer { releaseProcessingSlot() }

    do {
      let budgets = try repository.budgets()
      let states = try Dictionary(
        uniqueKeysWithValues: budgets.map {
          ($0.id, try repository.alertState(for: $0.id))
        }
      )
      let evaluation = engine.evaluate(
        pacing: snapshot.pacing,
        summary: snapshot.summary,
        budgets: budgets,
        storedStates: states,
        now: snapshot.evaluatedAt,
        calendar: snapshot.evaluationCalendar,
        allDataIsStale: snapshot.allDataIsStale
      )

      for state in evaluation.stateUpdates {
        try repository.saveAlertState(state)
      }
      for decision in evaluation.decisions {
        do {
          let acceptedState = try await deliver(decision)
          try repository.saveAlertState(acceptedState)
        } catch {
          return markingPartial(
            snapshot,
            diagnostic: String(describing: error)
          )
        }
      }
      return snapshot
    } catch {
      return markingPartial(
        snapshot,
        diagnostic: String(describing: error)
      )
    }
  }

  private func acquireProcessingSlot() async -> Bool {
    while isProcessing {
      await withCheckedContinuation {
        processingWaiters.append($0)
      }
      if Task.isCancelled {
        return false
      }
    }
    isProcessing = true
    return true
  }

  private func releaseProcessingSlot() {
    isProcessing = false
    let waiters = processingWaiters
    processingWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }

  private func markingPartial(
    _ snapshot: RefreshSnapshot,
    diagnostic: String
  ) -> RefreshSnapshot {
    let message = sanitizer.sanitize(diagnostic)
    var attempts = snapshot.attempts
    let enabledProviders = snapshot.providerStates.values
      .filter(\.isEnabled)
      .map(\.provider)
    let targets =
      enabledProviders.isEmpty
      ? ProviderID.allCases
      : enabledProviders
    for provider in targets {
      attempts[provider, default: []].append(
        SourceAttempt(
          strategyID: "budget-alert",
          outcome: .failed(redactedMessage: message)
        )
      )
    }
    let summary = MonthlySummary(
      total: snapshot.summary.total,
      actual: snapshot.summary.actual,
      estimated: snapshot.summary.estimated,
      providers: snapshot.summary.providers,
      isPartial: true
    )
    return RefreshSnapshot(
      summary: summary,
      pacing: snapshot.pacing,
      attempts: attempts,
      allDataIsStale: snapshot.allDataIsStale,
      refreshedAt: snapshot.refreshedAt,
      evaluatedAt: snapshot.evaluatedAt,
      monthWindow: snapshot.monthWindow,
      evaluationCalendar: snapshot.evaluationCalendar,
      providerStates: snapshot.providerStates,
      dataAvailability: snapshot.dataAvailability,
      providerAvailability: snapshot.providerAvailability
    )
  }
}
