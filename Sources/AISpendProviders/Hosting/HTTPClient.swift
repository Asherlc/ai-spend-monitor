import Foundation

public struct HTTPClient: Sendable {
  private let session: URLSession
  private let redactor: Redactor

  public init() {
    self.init(configuration: .ephemeral)
  }

  init(configuration: URLSessionConfiguration) {
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 20
    configuration.timeoutIntervalForResource = 20
    session = URLSession(
      configuration: configuration,
      delegate: HTTPRedirectDelegate(),
      delegateQueue: nil
    )
    redactor = Redactor()
  }

  public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    guard HTTPRequestPolicy.isAllowed(request) else {
      throw SourceHostError.domainNotAllowed
    }

    var boundedRequest = request
    boundedRequest.timeoutInterval = 20
    boundedRequest.cachePolicy = .reloadIgnoringLocalCacheData
    do {
      let (data, response) = try await session.data(for: boundedRequest)
      guard let httpResponse = response as? HTTPURLResponse else {
        throw SourceHostError.sourceUnavailable
      }
      return (data, httpResponse)
    } catch let error as SourceHostError {
      throw error
    } catch {
      throw SourceHostError.requestFailed(
        redactedMessage: redactor.redact(error.localizedDescription)
      )
    }
  }
}

final class HTTPRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func validatedRedirectRequest(_ request: URLRequest) -> URLRequest? {
    guard HTTPRequestPolicy.isAllowed(request) else {
      return nil
    }
    var sanitized = request
    for header in HTTPRequestPolicy.sensitiveHeaders {
      sanitized.setValue(nil, forHTTPHeaderField: header)
    }
    return sanitized
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(validatedRedirectRequest(request))
  }
}

private enum HTTPRequestPolicy {
  static let allowedHosts: Set<String> = [
    "api.anthropic.com",
    "api.cursor.com",
    "api.openai.com",
  ]

  static let sensitiveHeaders = [
    "Authorization",
    "Cookie",
    "Proxy-Authorization",
    "X-API-Key",
    "OpenAI-Organization",
    "anthropic-api-key",
  ]

  static func isAllowed(_ request: URLRequest) -> Bool {
    guard let url = request.url,
      url.scheme?.lowercased() == "https",
      let host = url.host?.lowercased(),
      allowedHosts.contains(host),
      url.user == nil,
      url.password == nil
    else {
      return false
    }
    return true
  }
}
