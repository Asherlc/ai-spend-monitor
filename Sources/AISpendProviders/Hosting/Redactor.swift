import AISpendCore

public struct Redactor: Sendable {
  private let sanitizer: DiagnosticSanitizer

  public init(sanitizer: DiagnosticSanitizer = DiagnosticSanitizer()) {
    self.sanitizer = sanitizer
  }

  public func redact(_ diagnostic: String) -> String {
    sanitizer.sanitize(diagnostic)
  }
}
