import AISpendCore
import Foundation

struct FireworksAccount: Hashable, Sendable {
  let resourceName: String
  let id: String
}

struct FireworksCostClient: Sendable {
  typealias Transport =
    @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

  private let http: Transport

  init(http: @escaping Transport) {
    self.http = http
  }

  init(httpClient: HTTPClient = HTTPClient()) {
    http = { request in try await httpClient.data(for: request) }
  }

  func accounts(credential: Secret) async throws -> [FireworksAccount] {
    var pageToken: String?
    var requestedPageTokens: Set<String> = []
    var pageCount = 0
    var accounts: [FireworksAccount] = []

    repeat {
      try Task.checkCancellation()
      guard pageCount < 100 else {
        throw ProviderClientError.invalidResponse
      }
      let pageKey = pageToken ?? "<first>"
      guard requestedPageTokens.insert(pageKey).inserted else {
        throw ProviderClientError.invalidResponse
      }
      pageCount += 1

      let request = try request(pageToken: pageToken, credential: credential)
      let (data, response) = try await http(request)
      guard response.statusCode == 200 else {
        throw ProviderClientError.httpStatus(response.statusCode)
      }
      let page = try JSONDecoder().decode(FireworksAccountsPage.self, from: data)
      accounts.append(contentsOf: try page.accounts.map { try Self.account(from: $0.name) })
      pageToken = page.nextPageToken.flatMap { $0.isEmpty ? nil : $0 }
    } while pageToken != nil

    return accounts
  }

  private func request(pageToken: String?, credential: Secret) throws -> URLRequest {
    var components = URLComponents(string: "https://api.fireworks.ai/v1/accounts")!
    components.queryItems = [
      URLQueryItem(name: "pageSize", value: "200")
    ]
    if let pageToken {
      components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken))
    }
    guard let url = components.url else {
      throw ProviderClientError.invalidResponse
    }
    var request = URLRequest(url: url)
    credential.withValue {
      request.setValue("Bearer \($0)", forHTTPHeaderField: "Authorization")
    }
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    return request
  }

  private static func account(from name: String) throws -> FireworksAccount {
    let components = name.split(separator: "/", omittingEmptySubsequences: false)
    guard components.count == 2,
      components[0] == "accounts",
      !components[1].isEmpty
    else {
      throw ProviderClientError.invalidResponse
    }
    return FireworksAccount(resourceName: name, id: String(components[1]))
  }
}

private struct FireworksAccountsPage: Decodable {
  let accounts: [FireworksAccountPayload]
  let nextPageToken: String?
}

private struct FireworksAccountPayload: Decodable {
  let name: String
}
