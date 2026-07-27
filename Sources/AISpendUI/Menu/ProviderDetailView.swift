import AISpendCore
import Charts
import SwiftUI

public struct ProviderDetailView: View {
  @Bindable private var model: AppModel
  private let provider: ProviderSpendSummary

  public init(model: AppModel, provider: ProviderSpendSummary) {
    self.model = model
    self.provider = provider
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          spendSummary
          modelBreakdown
          dailyTrend
          sourceDetails
        }
        .padding(16)
      }
    }
    .navigationTitle(provider.id.displayName)
  }

  private var header: some View {
    HStack {
      Button {
        model.selectedProvider = nil
      } label: {
        Label("Back", systemImage: "chevron.left")
          .labelStyle(.iconOnly)
      }
      .buttonStyle(.borderless)
      .help("Back to monthly spend")
      Text(provider.id.displayName)
        .font(.headline)
      Spacer()
      if let url = provider.id.dashboardURL {
        Link(destination: url) {
          Image(systemName: "arrow.up.right.square")
        }
        .help("Open \(provider.id.displayName) dashboard")
        .accessibilityLabel("Open \(provider.id.displayName) dashboard")
      }
    }
    .padding(12)
  }

  private var spendSummary: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(SpendFormatting.currency(provider.total))
        .font(.title.bold().monospacedDigit())
      Text(
        "\(SpendFormatting.share(model.providerShare(provider))) of combined spend"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      Text(
        "\(SpendFormatting.currency(provider.actual)) actual · "
          + "\(SpendFormatting.estimated(provider.estimated)) estimated"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private var modelBreakdown: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Models")
        .font(.headline)
      if provider.models.isEmpty {
        Text("This source did not provide a model breakdown.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ForEach(provider.models, id: \.model) { item in
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text(item.model)
                .lineLimit(1)
              Text(modelShare(item))
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
              Text(SpendFormatting.currency(item.total))
                .monospacedDigit()
              if item.estimated.amount > 0 {
                Text("ESTIMATED")
                  .font(.caption2.bold())
                  .foregroundStyle(.orange)
                  .accessibilityLabel(
                    "\(SpendFormatting.estimated(item.estimated)) estimated"
                  )
              }
            }
          }
          .accessibilityElement(children: .combine)
        }
      }
    }
  }

  @ViewBuilder
  private var dailyTrend: some View {
    let points = model.dailySpend(for: provider.id)
    VStack(alignment: .leading, spacing: 8) {
      Text("Daily spend")
        .font(.headline)
      if points.isEmpty {
        ContentUnavailableView(
          "No daily history",
          systemImage: "chart.xyaxis.line",
          description: Text("The active source did not return daily records.")
        )
        .frame(height: 90)
      } else {
        Chart(points) { point in
          AreaMark(
            x: .value("Day", point.date),
            y: .value("Spend", point.amount.decimalDouble)
          )
          .foregroundStyle(provider.id.tint.opacity(0.15))
          LineMark(
            x: .value("Day", point.date),
            y: .value("Spend", point.amount.decimalDouble)
          )
          .foregroundStyle(provider.id.tint)
          .interpolationMethod(.catmullRom)
        }
        .chartYAxis(.hidden)
        .frame(height: 90)
        .accessibilityLabel("Daily spend trend for \(provider.id.displayName)")
      }
    }
  }

  private var sourceDetails: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Sources & diagnostics")
        .font(.headline)
      Text(
        "Last refreshed \(SpendFormatting.relative(model.snapshot.refreshedAt))"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      if model.attempts(for: provider.id).isEmpty {
        Text("No source diagnostics reported.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ForEach(
          Array(model.attempts(for: provider.id).enumerated()),
          id: \.offset
        ) { _, attempt in
          HStack(alignment: .top, spacing: 8) {
            Image(systemName: attempt.symbol)
              .foregroundStyle(attempt.color)
            VStack(alignment: .leading, spacing: 2) {
              Text(attempt.strategyID)
              Text(attempt.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
          }
          .accessibilityElement(children: .combine)
        }
      }
    }
  }

  private func modelShare(_ item: ModelSpendSummary) -> String {
    guard provider.total.amount > 0 else { return "0% of provider" }
    return
      "\(SpendFormatting.share(item.total.amount / provider.total.amount)) of provider"
  }
}

extension Money {
  fileprivate var decimalDouble: Double {
    NSDecimalNumber(decimal: amount).doubleValue
  }
}

extension SourceAttempt {
  fileprivate var detail: String {
    switch outcome {
    case .succeeded(let count): "\(count) records"
    case .unavailable(let reason): reason
    case .failed(let message): message
    }
  }

  fileprivate var symbol: String {
    switch outcome {
    case .succeeded: "checkmark.circle.fill"
    case .unavailable: "minus.circle.fill"
    case .failed: "exclamationmark.triangle.fill"
    }
  }

  fileprivate var color: Color {
    switch outcome {
    case .succeeded: .green
    case .unavailable: .secondary
    case .failed: .orange
    }
  }
}
