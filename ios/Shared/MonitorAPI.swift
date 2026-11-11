import Foundation

/// Shared by the phone and the watch: one read-only snapshot fetch.
enum MonitorAPIError: LocalizedError {
    case badURL, response, unauthorized, expired, server(Int)

    var errorDescription: String? {
        switch self {
        case .badURL: "服务地址无效。"
        case .response: "服务返回无效响应。"
        case .unauthorized: "凭证已撤销，请重新配对。"
        case .expired: "配对码已过期或已使用，请重新生成。"
        case .server(let status): "服务请求失败（\(status)）。"
        }
    }
}

enum MonitorAPI {
    static func snapshot(base: String, token: String) async throws -> Snapshot {
        let trimmed = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed + "/v1/snapshot") else { throw MonitorAPIError.badURL }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MonitorAPIError.response }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw MonitorAPIError.unauthorized }
            if http.statusCode == 410 { throw MonitorAPIError.expired }
            throw MonitorAPIError.server(http.statusCode)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Snapshot.self, from: data)
    }
}