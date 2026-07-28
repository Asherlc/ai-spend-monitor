import Foundation

enum ProviderClientError: Error, Equatable, Sendable {
  case httpStatus(Int)
  case invalidResponse
  case unsupportedCurrency
}
