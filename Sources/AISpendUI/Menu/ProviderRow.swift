import AISpendCore
import SwiftUI

public struct ProviderRow: View {
  private let presentation: ProviderPresentation
  private let combinedTotal: Money
  private let action: () -> Void

  public init(
    presentation: ProviderPresentation,
    combinedTotal: Money,
    action: @escaping () -> Void
  ) {
    self.presentation = presentation
    self.combinedTotal = combinedTotal
    self.action = action
  }

  public var body: some View {
    let provider = presentation.summary
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: provider.id.symbolName)
          .frame(width: 22)
          .foregroundStyle(provider.id.tint)
        VStack(alignment: .leading, spacing: 2) {
          Text(provider.id.displayName)
            .foregroundStyle(.primary)
          Text(statusLine)
            .font(.caption)
            .foregroundStyle(statusColor)
        }
        Spacer()
        VStack(alignment: .trailing, spacing: 2) {
          if presentation.availability == .available {
            Text(presentation.amountTitle)
              .font(.callout.monospacedDigit().weight(.medium))
          } else {
            Text(presentation.amountTitle)
              .font(.callout)
              .foregroundStyle(.secondary)
          }
          if let amountDetail = presentation.amountDetail {
            Text(amountDetail)
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(
      accessibilityLabel
    )
    .help("Show \(provider.id.displayName) model and source details")
  }

  private var accessibilityLabel: String {
    let provider = presentation.summary
    guard presentation.availability == .available else {
      return "\(provider.id.displayName), no current data, \(statusLine)"
    }
    return "\(provider.id.displayName), \(presentation.amountTitle), \(share)"
  }

  private var share: String {
    let provider = presentation.summary
    guard combinedTotal.amount > 0 else { return "0% of total" }
    return "\(SpendFormatting.share(provider.total.amount / combinedTotal.amount)) of total"
  }

  private var statusLine: String {
    switch presentation.status.freshness {
    case .fresh:
      share
    case .stale(let age):
      "Stale · \(ageText(age))"
    case .cachedAfterFailure(let age, _):
      "Cached · \(ageText(age))"
    case .unavailable:
      "Unavailable"
    }
  }

  private var statusColor: Color {
    switch presentation.status.freshness {
    case .fresh: .secondary
    case .stale, .cachedAfterFailure, .unavailable: .orange
    }
  }

  private func ageText(_ age: TimeInterval) -> String {
    let minutes = max(1, Int(age / 60))
    return minutes < 60 ? "\(minutes)m old" : "\(minutes / 60)h old"
  }
}

extension ProviderID {
  public var displayName: String {
    ProviderDescriptor.builtIns.first { $0.id == self }?.displayName ?? rawValue
  }

  public var symbolName: String {
    switch self {
    case .cursor: "cursorarrow.rays"
    case .claude: "sparkles"
    case .openAI: "brain.head.profile"
    }
  }

  public var tint: Color {
    switch self {
    case .cursor: .blue
    case .claude: .orange
    case .openAI: .green
    }
  }

  public var dashboardURL: URL? {
    switch self {
    case .cursor: URL(string: "https://cursor.com/dashboard")
    case .claude: URL(string: "https://console.anthropic.com/settings/billing")
    case .openAI: URL(string: "https://platform.openai.com/usage")
    }
  }
}
