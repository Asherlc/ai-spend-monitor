import AISpendCore
import SwiftUI

public struct BudgetSettingsView: View {
  @Bindable private var model: AppModel
  @State private var newLimit = ""

  public init(model: AppModel) {
    self.model = model
  }

  public var body: some View {
    Form {
      if let error = model.settingsError {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
      }

      Section("Monthly budgets") {
        if model.budgets.isEmpty {
          ContentUnavailableView(
            "No budgets",
            systemImage: "gauge",
            description: Text("Add one or more combined monthly USD limits.")
          )
        } else {
          ForEach(model.budgets) { budget in
            BudgetEditorRow(
              budget: budget,
              evaluation: model.budgetEvaluations.first { $0.id == budget.id },
              update: { replacement in
                await model.updateBudget(replacement)
              },
              remove: {
                await model.removeBudget(id: budget.id)
              }
            )
          }
        }
      }

      Section {
        HStack {
          TextField("Amount in USD", text: $newLimit)
            .textFieldStyle(.roundedBorder)
            .onSubmit { addBudget() }
          Button("Add Budget") {
            addBudget()
          }
          .disabled(newLimit.isEmpty)
        }
        HStack {
          Text("Quick add:")
            .foregroundStyle(.secondary)
          Button("$500") {
            newLimit = "500"
            addBudget()
          }
          Button("$1,500") {
            newLimit = "1500"
            addBudget()
          }
        }
        .buttonStyle(.link)
      } footer: {
        Text(
          "Budgets apply to combined spend across enabled providers. Each level is paced and alerted independently."
        )
      }
    }
    .formStyle(.grouped)
  }

  private func addBudget() {
    let text = newLimit
    Task {
      if await model.addBudget(decimalText: text) == .success {
        newLimit = ""
      }
    }
  }
}

private struct BudgetEditorRow: View {
  let budget: BudgetDefinition
  let evaluation: BudgetEvaluation?
  let update: (BudgetDefinition) async -> BudgetValidationResult
  let remove: () async -> Void

  @State private var amountText: String

  init(
    budget: BudgetDefinition,
    evaluation: BudgetEvaluation?,
    update: @escaping (BudgetDefinition) async -> BudgetValidationResult,
    remove: @escaping () async -> Void
  ) {
    self.budget = budget
    self.evaluation = evaluation
    self.update = update
    self.remove = remove
    _amountText = State(
      initialValue: NSDecimalNumber(decimal: budget.limit.amount).stringValue
    )
  }

  var body: some View {
    HStack {
      Toggle(
        "Enabled",
        isOn: Binding(
          get: { budget.isEnabled },
          set: { enabled in
            var replacement = budget
            replacement.isEnabled = enabled
            Task { _ = await update(replacement) }
          }
        )
      )
      .labelsHidden()

      VStack(alignment: .leading, spacing: 3) {
        HStack {
          Text("$")
          TextField("Monthly limit", text: $amountText)
            .frame(width: 110)
            .onSubmit { saveAmount() }
          Button("Save") { saveAmount() }
        }
        Text(pacingText)
          .font(.caption)
          .foregroundStyle(.secondary)
        if let usageFraction = evaluation?.usageFraction {
          ProgressView(value: usageFraction)
            .progressViewStyle(.linear)
            .tint(progressColor)
            .frame(maxWidth: 220)
            .accessibilityLabel("Budget used")
            .accessibilityValue(
              SpendFormatting.share(Decimal(usageFraction))
            )
        }
      }

      Spacer()

      Button(role: .destructive) {
        Task { await remove() }
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(.borderless)
      .help("Remove budget")
    }
    .padding(.vertical, 3)
  }

  private var pacingText: String {
    guard budget.isEnabled else { return "Alerts disabled" }
    guard let evaluation else { return "Pace unavailable" }
    let state =
      switch evaluation.state {
      case .collecting: "Collecting pace"
      case .onPace: "On pace"
      case .offPace: "Off pace"
      case .unknown: "No current data"
      }
    let forecast = evaluation.exhaustionForecast.map {
      SpendFormatting.budgetForecast($0)
    }
    let detail = [state, forecast].compactMap { $0 }.joined(separator: " · ")
    guard let margin = evaluation.projectedMargin else { return detail }
    let direction = margin.amount >= 0 ? "under" : "over"
    let amount = Money(abs(margin.amount))
    return "\(detail) · \(SpendFormatting.currency(amount)) \(direction)"
  }

  private var progressColor: Color {
    evaluation?.state == .offPace ? .orange : .accentColor
  }

  private func saveAmount() {
    guard
      amountText.range(
        of: #"^[0-9]+(?:\.[0-9]+)?$"#,
        options: .regularExpression
      ) != nil,
      let amount = Decimal(
        string: amountText,
        locale: Locale(identifier: "en_US_POSIX")
      )
    else {
      var invalid = budget
      invalid.limit = .zero
      Task { _ = await update(invalid) }
      return
    }
    var replacement = budget
    replacement.limit = Money(amount)
    Task { _ = await update(replacement) }
  }
}
