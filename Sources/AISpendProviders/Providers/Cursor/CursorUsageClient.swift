import AISpendCore
import Foundation

enum CursorAuthorization: Sendable {
  case adminKey(Secret)
  case appToken(token: Secret, teamID: Secret)
}

struct CursorUsageResult: Sendable {
  let authoritativeCents: Decimal
  let modelCents: [String: Decimal]
}

struct CursorUsageClient: Sendable {
  typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
  private let http: Transport

  init(http: @escaping Transport) {
    self.http = http
  }

  init(httpClient: HTTPClient = HTTPClient()) {
    http = { request in try await httpClient.data(for: request) }
  }

  func fetch(
    window: MonthWindow,
    authorization: CursorAuthorization
  ) async throws -> CursorUsageResult {
    let authoritativeCents = try await fetchSpend(window: window, authorization: authorization)
    let modelCents = try await fetchUsage(window: window, authorization: authorization)
    return CursorUsageResult(authoritativeCents: authoritativeCents, modelCents: modelCents)
  }

  private func fetchSpend(
    window: MonthWindow,
    authorization: CursorAuthorization
  ) async throws -> Decimal {
    var page = 1
    var total: Decimal = 0
    while true {
      let request = try request(
        path: "/teams/spend",
        window: window,
        page: page,
        authorization: authorization
      )
      let (data, response) = try await http(request)
      guard response.statusCode == 200 else {
        throw ProviderClientError.httpStatus(response.statusCode)
      }
      let decoded = try JSONDecoder().decode(CursorSpendPage.self, from: data)
      total += decoded.teamMemberSpend.reduce(0) { $0 + $1.spendCents }
      guard page < decoded.totalPages else {
        return total
      }
      page += 1
    }
  }

  private func fetchUsage(
    window: MonthWindow,
    authorization: CursorAuthorization
  ) async throws -> [String: Decimal] {
    var page = 1
    var totals: [String: Decimal] = [:]
    while true {
      let request = try request(
        path: "/teams/filtered-usage-events",
        window: window,
        page: page,
        authorization: authorization
      )
      let (data, response) = try await http(request)
      guard response.statusCode == 200 else {
        throw ProviderClientError.httpStatus(response.statusCode)
      }
      let decoded = try JSONDecoder().decode(CursorUsagePage.self, from: data)
      for event in decoded.usageEvents
      where event.kind == "Usage-based"
        && event.isTokenBasedCall
        && window.contains(event.timestamp)
      {
        guard let cents = event.tokenUsage?.totalCents, cents >= 0 else {
          continue
        }
        totals[event.model ?? "unknown", default: 0] += cents
      }
      guard page < decoded.pagination.numPages else {
        return totals
      }
      page += 1
    }
  }

  private func request(
    path: String,
    window: MonthWindow,
    page: Int,
    authorization: CursorAuthorization
  ) throws -> URLRequest {
    let url = URL(string: "https://api.cursor.com\(path)")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    var body: [String: Any] = ["page": page, "pageSize": 100]
    if path.hasSuffix("/filtered-usage-events") {
      body["startDate"] = Self.day(window.start)
      body["endDate"] = Self.day(window.end)
    }
    switch authorization {
    case .adminKey(let secret):
      secret.withValue {
        let encoded = Data("\($0):".utf8).base64EncodedString()
        request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
      }
    case .appToken(let token, let teamID):
      token.withValue { request.setValue("Bearer \($0)", forHTTPHeaderField: "Authorization") }
      teamID.withValue {
        body["teamId"] = $0
        request.setValue($0, forHTTPHeaderField: "X-Cursor-Team-Id")
      }
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    return request
  }

  private static func day(_ date: Date) -> Int {
    Int(date.timeIntervalSince1970 * 1_000)
  }
}

private struct CursorSpendPage: Decodable {
  let teamMemberSpend: [CursorMemberSpend]
  let totalPages: Int
}

private struct CursorMemberSpend: Decodable {
  let spendCents: Decimal
}

private struct CursorUsagePage: Decodable {
  let usageEvents: [CursorUsageEvent]
  let pagination: CursorPagination
}

private struct CursorUsageEvent: Decodable {
  let kind: String
  let model: String?
  let timestamp: Date
  let isTokenBasedCall: Bool
  let tokenUsage: CursorTokenUsage?

  enum CodingKeys: String, CodingKey {
    case kind
    case model
    case timestamp
    case isTokenBasedCall
    case tokenUsage
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    kind = try container.decode(String.self, forKey: .kind)
    model = try container.decodeIfPresent(String.self, forKey: .model)
    isTokenBasedCall = try container.decode(Bool.self, forKey: .isTokenBasedCall)
    tokenUsage = try container.decodeIfPresent(CursorTokenUsage.self, forKey: .tokenUsage)
    let value = try container.decode(String.self, forKey: .timestamp)
    guard let milliseconds = Int64(value) else {
      throw ProviderClientError.invalidResponse
    }
    timestamp = Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
  }
}

private struct CursorTokenUsage: Decodable {
  let totalCents: Decimal
}

private struct CursorPagination: Decodable {
  let numPages: Int
}
