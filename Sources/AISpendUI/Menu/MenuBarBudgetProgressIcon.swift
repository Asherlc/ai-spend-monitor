import AISpendCore
import Foundation
import SwiftUI

public struct MenuBarBudgetProgress: Equatable, Sendable {
  public let fraction: Double
  public let percentage: Decimal
  public let limit: Money

  public var accessibilityLabel: String {
    "\(SpendFormatting.share(percentage / 100)) of \(SpendFormatting.currency(limit)) budget used"
  }

  public init(
    fraction: Double,
    percentage: Decimal,
    limit: Money
  ) {
    self.fraction = fraction
    self.percentage = percentage
    self.limit = limit
  }
}

public struct MenuBarBudgetProgressIcon: View {
  private let progress: MenuBarBudgetProgress

  public init(progress: MenuBarBudgetProgress) {
    self.progress = progress
  }

  public var body: some View {
    ZStack {
      Circle()
        .stroke(lineWidth: 1.5)
        .opacity(0.25)
      Circle()
        .trim(from: 0, to: progress.fraction)
        .stroke(
          style: StrokeStyle(
            lineWidth: 2,
            lineCap: .round
          )
        )
        .rotationEffect(.degrees(-90))
      Text("$")
        .font(.system(size: 10, weight: .semibold, design: .rounded))
    }
    .frame(width: 18, height: 18)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(progress.accessibilityLabel)
  }
}
