import AISpendCore
import Foundation

struct FireworksAccount: Hashable, Sendable {
  let resourceName: String
  let id: String
}

enum FireworksCostScope: String, Sendable {
  case account = "ACCOUNT"
  case personal = "SELF"
}

struct FireworksCostRow: Hashable, Sendable {
  let start: Date
  let end: Date
  let model: String
  let amount: Decimal
}

struct FireworksCostResult: Sendable {
  let rows: [FireworksCostRow]
  let subtotal: Decimal
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
      if let pageToken,
        !requestedPageTokens.insert(pageToken).inserted
      {
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

  func costs(
    account: FireworksAccount,
    window: MonthWindow,
    scope: FireworksCostScope,
    credential: Secret
  ) async throws -> FireworksCostResult {
    var pageToken: String?
    var requestedPageTokens: Set<String> = []
    var pageCount = 0
    var rows: [FireworksCostRow] = []
    var querySubtotal: Decimal?

    repeat {
      try Task.checkCancellation()
      guard pageCount < 100 else {
        throw ProviderClientError.invalidResponse
      }
      if let pageToken,
        !requestedPageTokens.insert(pageToken).inserted
      {
        throw ProviderClientError.invalidResponse
      }
      pageCount += 1

      let request = try costRequest(
        account: account,
        window: window,
        scope: scope,
        pageToken: pageToken,
        credential: credential
      )
      let (data, response) = try await http(request)
      guard response.statusCode == 200 else {
        throw ProviderClientError.httpStatus(response.statusCode)
      }
      let page: FireworksCostPage
      do {
        page = try JSONDecoder().decode(FireworksCostPage.self, from: data)
      } catch {
        throw ProviderClientError.invalidResponse
      }
      let subtotal = try page.subtotal.decimalAmount()
      if let querySubtotal, querySubtotal != subtotal {
        throw ProviderClientError.invalidResponse
      }
      querySubtotal = subtotal
      rows.append(
        contentsOf: try page.rows.map {
          try $0.costRow(window: window)
        }
      )
      pageToken = page.nextPageToken.flatMap { $0.isEmpty ? nil : $0 }
    } while pageToken != nil

    guard let querySubtotal else {
      throw ProviderClientError.invalidResponse
    }
    return FireworksCostResult(rows: rows, subtotal: querySubtotal)
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

  private func costRequest(
    account: FireworksAccount,
    window: MonthWindow,
    scope: FireworksCostScope,
    pageToken: String?,
    credential: Secret
  ) throws -> URLRequest {
    let url = URL(string: "https://api.fireworks.ai")!
      .appending(path: "v1")
      .appending(path: "accounts")
      .appending(path: account.id)
      .appending(path: "usageCosts:query")
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = try JSONEncoder().encode(
      FireworksCostQuery(
        startTime: Self.timestamp(window.start),
        endTime: Self.timestamp(window.end),
        scope: scope.rawValue,
        pageToken: pageToken
      )
    )
    credential.withValue {
      request.setValue("Bearer \($0)", forHTTPHeaderField: "Authorization")
    }
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    return request
  }

  private static func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
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

private struct FireworksCostQuery: Encodable {
  let startTime: String
  let endTime: String
  let scope: String
  let groupBy = ["DAY", "MODEL"]
  let pageSize = 1000
  let pageToken: String?
}

private struct FireworksCostPage: Decodable {
  let rows: [FireworksCostPayload]
  let nextPageToken: String?
  let subtotal: FireworksMoneyPayload
}

private struct FireworksCostPayload: Decodable {
  let dimensions: FireworksDimensionsPayload
  let subtotal: FireworksMoneyPayload

  func costRow(window: MonthWindow) throws -> FireworksCostRow {
    let formatter = ISO8601DateFormatter()
    guard let decodedStart = formatter.date(from: dimensions.startTime) else {
      throw ProviderClientError.invalidResponse
    }
    let dayEnd = decodedStart.addingTimeInterval(24 * 60 * 60)
    let start = max(decodedStart, window.start)
    let end = min(dayEnd, window.end)
    guard start < end else {
      throw ProviderClientError.invalidResponse
    }
    return FireworksCostRow(
      start: start,
      end: end,
      model: dimensions.model ?? "unknown",
      amount: try subtotal.decimalAmount()
    )
  }
}

private struct FireworksDimensionsPayload: Decodable {
  let startTime: String
  let model: String?
  let unknownModel: Bool?
}

private struct FireworksMoneyPayload: Decodable {
  let currencyCode: String
  let units: String
  let nanos: Int

  func decimalAmount() throws -> Decimal {
    guard currencyCode == "USD" else {
      throw ProviderClientError.unsupportedCurrency
    }
    guard
      let whole = Decimal(
        string: units,
        locale: Locale(identifier: "en_US_POSIX")
      ),
      nanos >= 0,
      nanos <= 999_999_999
    else {
      throw ProviderClientError.invalidResponse
    }
    return whole + Decimal(nanos) / Decimal(1_000_000_000)
  }
}
