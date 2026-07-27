import AISpendCore
import SwiftUI

public struct ProviderRow: View {
  private let provider: ProviderSpendSummary
  private let combinedTotal: Money
  private let action: () -> Void

  public init(
    provider: ProviderSpendSummary,
    combinedTotal: Money,
    action: @escaping () -> Void
  ) {
    self.provider = provider
    self.combinedTotal = combinedTotal
    self.action = action
  }

  public var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: provider.id.symbolName)
          .frame(width: 22)
          .foregroundStyle(provider.id.tint)
        VStack(alignment: .leading, spacing: 2) {
          Text(provider.id.displayName)
            .foregroundStyle(.primary)
          Text(share)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        VStack(alignment: .trailing, spacing: 2) {
          Text(SpendFormatting.currency(provider.total))
            .font(.callout.monospacedDigit().weight(.medium))
          if provider.estimated.amount > 0 {
            Text("\(SpendFormatting.estimated(provider.estimated)) estimated")
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
      "\(provider.id.displayName), \(SpendFormatting.currency(provider.total)), \(share)"
    )
    .help("Show \(provider.id.displayName) model and source details")
  }

  private var share: String {
    guard combinedTotal.amount > 0 else { return "0% of total" }
    return "\(SpendFormatting.share(provider.total.amount / combinedTotal.amount)) of total"
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
