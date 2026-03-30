import Foundation

enum TransportError: Error {
    case serverError(String)
    case httpError(Int)
}

/// HTTP транспорт для отправки батчей событий.
final class NetworkTransport {

    private let batchURL: URL
    private let apiKey: String
    private let encoder: JSONEncoder

    init(endpoint: String, apiKey: String) {
        self.batchURL = URL(string: endpoint.trimmingCharacters(in: .init(charactersIn: "/")) + "/ingest/batch")!
        self.apiKey = apiKey
        self.encoder = JSONEncoder()
        // ISO8601 с миллисекундами
        self.encoder.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try c.encode(iso.string(from: date))
        }
    }

    func sendBatch(_ events: [SemetricsEvent]) async throws {
        let payload = BatchPayload(events: events)
        let body = try encoder.encode(payload)

        var request = URLRequest(url: batchURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.httpBody = body
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw TransportError.httpError(httpResponse.statusCode)
        }

        let serverResponse = try JSONDecoder().decode(ServerResponse.self, from: data)
        if !serverResponse.status.code.isEmpty {
            throw TransportError.serverError(serverResponse.status.message ?? serverResponse.status.code)
        }
    }
}
