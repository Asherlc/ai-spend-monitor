import SwiftUI

public struct SettingsView: View {
  @Bindable private var model: AppModel

  public init(model: AppModel) {
    self.model = model
  }

  public var body: some View {
    TabView(selection: $model.selectedSettingsTab) {
      ProviderSettingsView(model: model)
        .tabItem { Label("Providers", systemImage: "square.stack.3d.up") }
        .tag(SettingsTab.providers)

      BudgetSettingsView(model: model)
        .tabItem { Label("Budgets", systemImage: "gauge.with.dots.needle.67percent") }
        .tag(SettingsTab.budgets)

      PrivacySettingsView(model: model)
        .tabItem { Label("Privacy", systemImage: "hand.raised") }
        .tag(SettingsTab.privacy)
    }
    .frame(minWidth: 560, minHeight: 430)
  }
}
