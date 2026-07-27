import Foundation

public protocol Clock: Sendable {
  var now: Date { get }
}
