import AISpendCore
import Foundation

enum ProviderClientError: Error, Equatable, Sendable {
  case httpStatus(Int)
  case invalidResponse
}

enum ClaudeCredential: Sendable {
  case adminKey(Secret)
  case bearerToken(Secret)
}

struct ClaudeCostRow: Sendable {
  let start: Date
  let end: Date
  let amount: Decimal
  let description: String
  let model: String?
}

struct ClaudeCostClient: Sendable {
  typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

  private let http: Transport

  init(http: @escaping Transport) {
    self.http = http
  }

  init(httpClient: HTTPClient = HTTPClient()) {
    http = { request in try await httpClient.data(for: request) }
  }

  func fetch(window: MonthWindow, credential: ClaudeCredential) async throws -> [ClaudeCostRow] {
    var page: String?
    var requestedPages: Set<String> = []
    var pageCount = 0
    var rows: [ClaudeCostRow] = []
    repeat {
      try Task.checkCancellation()
      guard pageCount < 100 else {
        throw ProviderClientError.invalidResponse
      }
      let pageKey = page ?? "<first>"
      guard requestedPages.insert(pageKey).inserted else {
        throw ProviderClientError.invalidResponse
      }
      pageCount += 1
      let request = try request(window: window, page: page, credential: credential)
      let (data, response) = try await http(request)
      guard response.statusCode == 200 else {
        throw ProviderClientError.httpStatus(response.statusCode)
      }
      let decoded = try JSONDecoder().decode(CostPage.self, from: data)
      rows.append(contentsOf: decoded.rows())
      page = decoded.hasMore ? decoded.nextPage : nil
      if decoded.hasMore, page == nil {
        throw ProviderClientError.invalidResponse
      }
    } while page != nil
    return rows
  }

  private func request(
    window: MonthWindow,
    page: String?,
    credential: ClaudeCredential
  ) throws -> URLRequest {
    var components = URLComponents(
      string: "https://api.anthropic.com/v1/organizations/cost_report")!
    components.queryItems = [
      URLQueryItem(name: "starting_at", value: Self.timestamp(window.start)),
      URLQueryItem(name: "ending_at", value: Self.timestamp(window.end)),
      URLQueryItem(name: "bucket_width", value: "1d"),
      URLQueryItem(name: "group_by[]", value: "description"),
    ]
    if let page {
      components.queryItems?.append(URLQueryItem(name: "page", value: page))
    }
    guard let url = components.url else {
      throw ProviderClientError.invalidResponse
    }
    var request = URLRequest(url: url)
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    switch credential {
    case .adminKey(let secret):
      secret.withValue { request.setValue($0, forHTTPHeaderField: "x-api-key") }
    case .bearerToken(let secret):
      secret.withValue { request.setValue("Bearer \($0)", forHTTPHeaderField: "Authorization") }
    }
    return request
  }

  private static func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
  }
}

private struct CostPage: Decodable {
  let data: [CostBucket]
  let hasMore: Bool
  let nextPage: String?

  enum CodingKeys: String, CodingKey {
    case data
    case hasMore = "has_more"
    case nextPage = "next_page"
  }

  func rows() -> [ClaudeCostRow] {
    data.flatMap { bucket in
      bucket.results.compactMap { result in
        guard result.currency.uppercased() == "USD",
          let lowestUnits = Decimal(
            string: result.amount,
            locale: Locale(identifier: "en_US_POSIX")
          )
        else {
          return nil
        }
        return ClaudeCostRow(
          start: bucket.startingAt,
          end: bucket.endingAt,
          amount: lowestUnits / 100,
          description: result.description ?? "unknown",
          model: result.model
        )
      }
    }
  }
}

private struct CostBucket: Decodable {
  let startingAt: Date
  let endingAt: Date
  let results: [CostResult]

  enum CodingKeys: String, CodingKey {
    case startingAt = "starting_at"
    case endingAt = "ending_at"
    case results
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let formatter = ISO8601DateFormatter()
    guard
      let start = formatter.date(from: try container.decode(String.self, forKey: .startingAt)),
      let end = formatter.date(from: try container.decode(String.self, forKey: .endingAt))
    else {
      throw ProviderClientError.invalidResponse
    }
    startingAt = start
    endingAt = end
    results = try container.decode([CostResult].self, forKey: .results)
  }
}

private struct CostResult: Decodable {
  let amount: String
  let currency: String
  let description: String?
  let model: String?
}
