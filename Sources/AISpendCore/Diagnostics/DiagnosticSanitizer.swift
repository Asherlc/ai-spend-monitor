import Foundation

public struct DiagnosticSanitizer: Sendable {
  public init() {}

  public func sanitize(_ diagnostic: String) -> String {
    let patterns = [
      (
        #"(?i)(["']?authorization["']?\s*[:=]\s*["']?)[^"'\r\n,}]+"#,
        "$1[REDACTED]"
      ),
      (
        #"(?i)(["']?cookie["']?\s*[:=]\s*["']?)[^"'\r\n,}]+"#,
        "$1[REDACTED]"
      ),
      (
        #"(?i)(["']?(?:api[_-]?key|admin[_-]?key)["']?\s*[:=]\s*["']?)[^"'\s\r\n,}]+"#,
        "$1[REDACTED]"
      ),
      (
        #"(?i)(["']?account[_ -]?id["']?\s*[:=]\s*["']?)[^"'\s\r\n,}]+"#,
        "$1[REDACTED]"
      ),
      (
        #"\beyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#,
        "[REDACTED]"
      ),
      (
        #"\b(?:sk|rk|pk)-[A-Za-z0-9_-]{8,}\b"#,
        "[REDACTED]"
      ),
      (
        #"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#,
        "[REDACTED]"
      ),
      (
        #"\bacct_[A-Za-z0-9_-]+\b"#,
        "[REDACTED]"
      ),
    ]

    return patterns.reduce(diagnostic) { redacted, pattern in
      redacted.replacingOccurrences(
        of: pattern.0,
        with: pattern.1,
        options: [.regularExpression, .caseInsensitive]
      )
    }
  }
}
