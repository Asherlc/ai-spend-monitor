import AISpendCore
import Foundation

struct OpenAICostRow: Sendable {
  let start: Date
  let end: Date
  let amount: Decimal
  let model: String
  let projectID: String?
  let lineItem: String?
}

struct OpenAICostClient: Sendable {
  typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
  private let http: Transport

  init(http: @escaping Transport) {
    self.http = http
  }

  init(httpClient: HTTPClient = HTTPClient()) {
    http = { request in try await httpClient.data(for: request) }
  }

  func fetch(window: MonthWindow, credential: Secret) async throws -> [OpenAICostRow] {
    var page: String?
    var rows: [OpenAICostRow] = []
    repeat {
      let request = try request(window: window, page: page, credential: credential)
      let (data, response) = try await http(request)
      guard response.statusCode == 200 else {
        throw ProviderClientError.httpStatus(response.statusCode)
      }
      let decoded = try JSONDecoder().decode(OpenAIPage.self, from: data)
      rows.append(contentsOf: decoded.rows)
      page = decoded.hasMore ? decoded.nextPage : nil
      if decoded.hasMore, page == nil {
        throw ProviderClientError.invalidResponse
      }
    } while page != nil
    return rows
  }

  private func request(window: MonthWindow, page: String?, credential: Secret) throws -> URLRequest
  {
    var components = URLComponents(string: "https://api.openai.com/v1/organization/costs")!
    components.queryItems = [
      URLQueryItem(name: "start_time", value: String(Int(window.start.timeIntervalSince1970))),
      URLQueryItem(name: "end_time", value: String(Int(window.end.timeIntervalSince1970))),
      URLQueryItem(name: "bucket_width", value: "1d"),
      URLQueryItem(name: "limit", value: "31"),
      URLQueryItem(name: "group_by", value: "project_id"),
      URLQueryItem(name: "group_by", value: "line_item"),
    ]
    if let page {
      components.queryItems?.append(URLQueryItem(name: "page", value: page))
    }
    guard let url = components.url else {
      throw ProviderClientError.invalidResponse
    }
    var request = URLRequest(url: url)
    credential.withValue { request.setValue("Bearer \($0)", forHTTPHeaderField: "Authorization") }
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    return request
  }
}

private struct OpenAIPage: Decodable {
  let data: [OpenAIBucket]
  let hasMore: Bool
  let nextPage: String?

  enum CodingKeys: String, CodingKey {
    case data
    case hasMore = "has_more"
    case nextPage = "next_page"
  }

  var rows: [OpenAICostRow] {
    data.flatMap { bucket in
      bucket.results.compactMap { result in
        guard result.amount.currency.uppercased() == "USD" else {
          return nil
        }
        return OpenAICostRow(
          start: Date(timeIntervalSince1970: TimeInterval(bucket.startTime)),
          end: Date(timeIntervalSince1970: TimeInterval(bucket.endTime)),
          amount: result.amount.value,
          model: result.model ?? result.lineItem ?? "unknown",
          projectID: result.projectID,
          lineItem: result.lineItem
        )
      }
    }
  }
}

private struct OpenAIBucket: Decodable {
  let startTime: Int
  let endTime: Int
  let results: [OpenAIResult]

  enum CodingKeys: String, CodingKey {
    case startTime = "start_time"
    case endTime = "end_time"
    case results
  }
}

private struct OpenAIResult: Decodable {
  let amount: DecimalAmount
  let lineItem: String?
  let projectID: String?
  let model: String?

  enum CodingKeys: String, CodingKey {
    case amount
    case lineItem = "line_item"
    case projectID = "project_id"
    case model
  }
}

private struct DecimalAmount: Decodable {
  let value: Decimal
  let currency: String

  enum CodingKeys: CodingKey {
    case value
    case currency
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    currency = try container.decode(String.self, forKey: .currency)
    if let string = try? container.decode(String.self, forKey: .value),
      let decimal = Decimal(string: string, locale: Locale(identifier: "en_US_POSIX"))
    {
      value = decimal
    } else {
      value = try container.decode(Decimal.self, forKey: .value)
    }
  }
}
