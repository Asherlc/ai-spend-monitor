import SwiftUI

public struct PrivacySettingsView: View {
  @Bindable private var model: AppModel

  public init(model: AppModel) {
    self.model = model
  }

  public var body: some View {
    Form {
      if let error = model.settingsError {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
      }

      Section("Discovery") {
        Toggle(
          "Reuse authenticated browser and app sessions",
          isOn: Binding(
            get: { model.browserDiscoveryEnabled },
            set: { enabled in
              Task { await model.setBrowserDiscoveryEnabled(enabled) }
            }
          )
        )
        Text(
          "When off, browser-session strategies are skipped. CLI credentials and local usage logs remain available for enabled providers."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Section("Permissions") {
        permission(
          icon: "folder",
          title: "Local data",
          detail: "Reads only documented provider configuration and usage-log locations."
        )
        permission(
          icon: "key",
          title: "Keychain",
          detail:
            "Reuses allowlisted credentials in place; secrets are never copied into the spend ledger."
        )
        permission(
          icon: "safari",
          title: "Browser and app sessions",
          detail: "Session material stays in the source application or transient memory."
        )
        permission(
          icon: "bell",
          title: "Notifications",
          detail: "Requested when the first enabled budget needs pacing alerts."
        )
      }

      Section("Data handling") {
        Label("No analytics or telemetry", systemImage: "checkmark.shield")
        LabeledContent(
          "Local storage",
          value: "~/Library/Application Support/AISpendBar"
        )
        Text(
          "Normalized spend, budgets, alert state, and refresh metadata stay on this Mac."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  private func permission(
    icon: String,
    title: String,
    detail: String
  ) -> some View {
    LabeledContent {
      Text(detail)
        .foregroundStyle(.secondary)
    } label: {
      Label(title, systemImage: icon)
    }
  }
}
