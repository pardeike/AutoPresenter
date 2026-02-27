import Foundation

enum OpenAIRealtimeTokenError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case requestFailed(statusCode: Int, message: String)
    case missingClientSecret

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "OPENAI_API_KEY is missing."
        case .invalidResponse:
            return "OpenAI API returned an invalid response."
        case .requestFailed(let statusCode, let message):
            return "OpenAI API request failed (\(statusCode)): \(message)"
        case .missingClientSecret:
            return "OpenAI API response did not include a client secret value."
        }
    }
}

actor OpenAIRealtimeTokenService {
    private let endpoint = URL(string: "https://api.openai.com/v1/realtime/client_secrets")!

    func mintClientSecret(apiKey: String, model: String) async throws -> String {
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAPIKey.isEmpty else {
            throw OpenAIRealtimeTokenError.missingAPIKey
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(trimmedAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ClientSecretRequest(session: .init(model: model)))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIRealtimeTokenError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "<empty body>"
            throw OpenAIRealtimeTokenError.requestFailed(statusCode: httpResponse.statusCode, message: message)
        }

        let decoded = try JSONDecoder().decode(ClientSecretResponse.self, from: data)
        if let value = decoded.value {
            return value
        }
        if let value = decoded.clientSecret?.value {
            return value
        }
        throw OpenAIRealtimeTokenError.missingClientSecret
    }
}

private struct ClientSecretRequest: Encodable {
    let session: RealtimeSessionConfig
}

private struct RealtimeSessionConfig: Encodable {
    let type = "realtime"
    let model: String
}

private struct ClientSecretResponse: Decodable {
    let value: String?
    let clientSecret: NestedClientSecret?

    enum CodingKeys: String, CodingKey {
        case value
        case clientSecret = "client_secret"
    }
}

private struct NestedClientSecret: Decodable {
    let value: String
}
