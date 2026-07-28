import AISpendCore
import SwiftUI

public struct ProviderDiagnosticsView: View {
  @Bindable private var model: AppModel
  private let provider: ProviderID
  @Environment(\.dismiss) private var dismiss

  public init(model: AppModel, provider: ProviderID) {
    self.model = model
    self.provider = provider
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Label(provider.displayName, systemImage: provider.symbolName)
          .font(.title2.weight(.semibold))
        Spacer()
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
      }

      Text(
        "Source outcomes are sanitized before display. Credentials, cookies, authorization headers, emails, and account identifiers are never shown."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      if model.diagnosticEntries(for: provider).isEmpty {
        ContentUnavailableView(
          "No diagnostics",
          systemImage: "stethoscope",
          description: Text("This provider has not reported a source attempt yet.")
        )
      } else {
        List(model.diagnosticEntries(for: provider)) { entry in
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text(entry.strategyID)
                .font(.headline)
              Spacer()
              Text(entry.outcome)
                .font(.caption.weight(.medium))
                .foregroundStyle(
                  entry.outcome == "Succeeded" ? .green : .orange
                )
            }
            Text(entry.detail)
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
          .padding(.vertical, 4)
        }
      }
    }
    .padding(20)
    .frame(minWidth: 520, minHeight: 340)
  }
}
