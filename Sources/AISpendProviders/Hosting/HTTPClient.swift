import Foundation

public struct HTTPClient: Sendable {
  private static let allowedHosts: Set<String> = [
    "api.anthropic.com",
    "api.cursor.com",
    "api.openai.com",
  ]

  private let session: URLSession
  private let redactor: Redactor

  public init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 20
    configuration.timeoutIntervalForResource = 20
    session = URLSession(configuration: configuration)
    redactor = Redactor()
  }

  public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    guard let url = request.url,
      url.scheme?.lowercased() == "https",
      let host = url.host?.lowercased(),
      Self.allowedHosts.contains(host),
      url.user == nil,
      url.password == nil
    else {
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
