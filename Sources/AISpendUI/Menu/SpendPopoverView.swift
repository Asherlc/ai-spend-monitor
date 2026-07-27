import AISpendCore
import AppKit
import SwiftUI

public struct SpendPopoverView: View {
  @Bindable private var model: AppModel

  public init(model: AppModel) {
    self.model = model
  }

  public var body: some View {
    Group {
      if let provider = model.selectedProviderSummary {
        ProviderDetailView(model: model, provider: provider)
      } else {
        overview
      }
    }
    .frame(width: 360, height: 520)
    .task { await model.popoverOpened() }
  }

  private var overview: some View {
    VStack(alignment: .leading, spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          headline
          statusNotice
          projection
          budgets
          providers
        }
        .padding(16)
      }
      Divider()
      footer
    }
  }

  private var headline: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(model.monthTitle.uppercased())
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      Text(SpendFormatting.currency(model.snapshot.summary.total))
        .font(.system(size: 34, weight: .bold, design: .rounded))
        .monospacedDigit()
        .accessibilityLabel(
          "Combined monthly spend \(SpendFormatting.currency(model.snapshot.summary.total))"
        )
      Text(
        "\(SpendFormatting.currency(model.snapshot.summary.actual)) actual · "
          + "\(SpendFormatting.estimated(model.snapshot.summary.estimated)) estimated"
      )
      .font(.callout)
      .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var statusNotice: some View {
    if model.snapshot.allDataIsStale {
      notice(
        "All data is stale",
        detail: "The displayed total is cached. Refresh to retry provider sources.",
        symbol: "exclamationmark.triangle.fill"
      )
    } else if model.snapshot.summary.isPartial {
      notice(
        "Partial total",
        detail: "At least one enabled provider is unavailable or stale.",
        symbol: "exclamationmark.circle.fill"
      )
    } else if model.snapshot.pacing.isCollecting {
      notice(
        "Collecting pace",
        detail: "Projection begins after six hours of calendar-month data.",
        symbol: "hourglass"
      )
    }
  }

  private var projection: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("PROJECTED MONTH END")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      if let projection = model.snapshot.pacing.projection {
        Text(SpendFormatting.currency(projection))
          .font(.title3.bold().monospacedDigit())
        if model.snapshot.pacing.isPartial {
          Text("Projection uses partial or stale data")
            .font(.caption)
            .foregroundStyle(.orange)
        }
      } else {
        Text(model.snapshot.pacing.isCollecting ? "Collecting pace" : "Unavailable")
          .font(.title3.weight(.medium))
          .foregroundStyle(.secondary)
      }
    }
  }

  private var budgets: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("BUDGETS")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      if model.budgetEvaluations.isEmpty {
        Text("No enabled budgets")
          .font(.callout)
          .foregroundStyle(.secondary)
      } else {
        ForEach(model.budgetEvaluations) { evaluation in
          BudgetPaceRow(evaluation: evaluation)
        }
      }
    }
  }

  private var providers: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("PROVIDERS")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      if model.providerSummaries.isEmpty {
        ContentUnavailableView(
          "No spend yet",
          systemImage: "dollarsign.circle",
          description: Text("Refresh or enable providers in Settings.")
        )
        .frame(maxWidth: .infinity)
      } else {
        ForEach(model.providerSummaries) { provider in
          ProviderRow(
            provider: provider,
            combinedTotal: model.snapshot.summary.total
          ) {
            model.selectedProvider = provider.id
          }
        }
      }
    }
  }

  private var footer: some View {
    HStack {
      Text("Updated \(SpendFormatting.relative(model.snapshot.refreshedAt))")
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer()
      Button {
        Task { await model.refresh() }
      } label: {
        if model.isRefreshing {
          ProgressView()
            .controlSize(.small)
        } else {
          Image(systemName: "arrow.clockwise")
        }
      }
      .buttonStyle(.borderless)
      .disabled(model.isRefreshing)
      .help("Refresh spend")
      .accessibilityLabel("Refresh spend")
      SettingsLink {
        Image(systemName: "gearshape")
      }
      .buttonStyle(.borderless)
      .help("Open Settings")
      .accessibilityLabel("Open Settings")
    }
    .padding(12)
  }

  private func notice(
    _ title: String,
    detail: String,
    symbol: String
  ) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: symbol)
        .foregroundStyle(.orange)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.callout.weight(.semibold))
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    .accessibilityElement(children: .combine)
  }
}
