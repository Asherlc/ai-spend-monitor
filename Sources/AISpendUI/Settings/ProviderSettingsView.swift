import AISpendCore
import SwiftUI

public struct ProviderSettingsView: View {
  @Bindable private var model: AppModel
  @State private var diagnosticProvider: ProviderID?

  public init(model: AppModel) {
    self.model = model
  }

  public var body: some View {
    Form {
      if let error = model.settingsError {
        settingsError(error)
      }

      Section {
        ForEach(model.providerSettings) { provider in
          providerRow(provider)
        }
      } header: {
        Text("Spend providers")
      } footer: {
        Text(
          "Disabled providers are excluded from totals and perform no credential, file, browser, subprocess, or network discovery."
        )
      }
    }
    .formStyle(.grouped)
    .sheet(
      isPresented: Binding(
        get: { diagnosticProvider != nil },
        set: { if !$0 { diagnosticProvider = nil } }
      )
    ) {
      if let diagnosticProvider {
        ProviderDiagnosticsView(model: model, provider: diagnosticProvider)
      }
    }
  }

  private func providerRow(
    _ provider: ProviderSettingPresentation
  ) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: provider.id.symbolName)
        .font(.title3)
        .foregroundStyle(provider.id.tint)
        .frame(width: 24)

      VStack(alignment: .leading, spacing: 4) {
        Text(provider.displayName)
          .font(.headline)
        Text(discoveryText(provider))
          .font(.caption)
          .foregroundStyle(.secondary)
        if !provider.activeSources.isEmpty {
          Text("Active: \(provider.activeSources.joined(separator: ", "))")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if let success = provider.status.lastSuccessfulAt {
          Text("Last success \(SpendFormatting.relative(success))")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Spacer()

      Button("Diagnostics") {
        diagnosticProvider = provider.id
      }
      .buttonStyle(.link)

      Toggle(
        "Enable \(provider.displayName)",
        isOn: Binding(
          get: { provider.isEnabled },
          set: { enabled in
            Task { await model.setProvider(provider.id, enabled: enabled) }
          }
        )
      )
      .labelsHidden()
    }
    .padding(.vertical, 4)
  }

  private func discoveryText(
    _ provider: ProviderSettingPresentation
  ) -> String {
    guard provider.isEnabled else { return "Disabled" }
    switch provider.status.freshness {
    case .fresh:
      let hasActual = provider.activeSources.contains {
        !$0.localizedCaseInsensitiveContains("local")
          && !$0.localizedCaseInsensitiveContains("estimate")
      }
      let hasEstimate = provider.activeSources.contains {
        $0.localizedCaseInsensitiveContains("local")
          || $0.localizedCaseInsensitiveContains("estimate")
      }
      if hasActual && hasEstimate { return "Actual and estimate available" }
      if hasActual { return "Actual available" }
      if hasEstimate { return "Estimate available" }
      return "Available"
    case .partial:
      return "Limited"
    case .stale:
      return "Stale"
    case .cachedAfterFailure:
      return "Error — showing cached data"
    case .unavailable:
      return "Unavailable"
    }
  }

  private func settingsError(_ message: String) -> some View {
    Label(message, systemImage: "exclamationmark.triangle.fill")
      .foregroundStyle(.orange)
      .accessibilityLabel("Settings error: \(message)")
  }
}
