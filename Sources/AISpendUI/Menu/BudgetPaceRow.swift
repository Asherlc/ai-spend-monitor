import AISpendCore
import SwiftUI

public struct BudgetPaceRow: View {
  private let evaluation: BudgetEvaluation

  public init(evaluation: BudgetEvaluation) {
    self.evaluation = evaluation
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 10) {
        Image(systemName: symbol)
          .foregroundStyle(color)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text("\(SpendFormatting.currency(evaluation.limit)) budget")
            .font(.callout.weight(.medium))
          Text(stateLabel)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if let margin = evaluation.projectedMargin {
          Text(marginText(margin))
            .font(.caption.monospacedDigit())
            .foregroundStyle(margin.amount >= 0 ? .secondary : color)
        }
      }
      if let usageFraction = evaluation.usageFraction {
        ProgressView(value: usageFraction)
          .progressViewStyle(.linear)
          .tint(color)
          .accessibilityLabel("Budget used")
          .accessibilityValue(
            SpendFormatting.share(Decimal(usageFraction))
          )
      }
    }
    .accessibilityElement(children: .combine)
  }

  private var stateLabel: String {
    if let forecast = evaluation.exhaustionForecast {
      return SpendFormatting.budgetForecast(forecast)
    }
    return switch evaluation.state {
    case .collecting: "Collecting pace"
    case .onPace: "On pace"
    case .offPace: "Off pace"
    case .unknown: "No current data"
    }
  }

  private var symbol: String {
    switch evaluation.state {
    case .onPace: "checkmark.circle.fill"
    case .offPace: "exclamationmark.circle.fill"
    case .collecting: "hourglass.circle.fill"
    case .unknown: "questionmark.circle.fill"
    }
  }

  private var color: Color {
    switch evaluation.state {
    case .onPace: .green
    case .offPace: .orange
    case .collecting, .unknown: .secondary
    }
  }

  private func marginText(_ margin: Money) -> String {
    if margin.amount >= 0 {
      return "\(SpendFormatting.currency(margin)) under"
    }
    return "\(SpendFormatting.currency(Money(-margin.amount))) over"
  }
}
