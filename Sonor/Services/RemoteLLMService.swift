import Foundation

struct RemoteLLMConfiguration: Sendable {
    let baseURL: String
    let apiKey: String
    let modelName: String
    let temperature: Double
}

enum RemoteLLMError: LocalizedError {
    case invalidBaseURL
    case requestFailed(status: Int, message: String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return t("The API endpoint is not a valid URL.")
        case .requestFailed(let status, let message):
            return message.isEmpty ? "HTTP \(status)" : "HTTP \(status): \(message)"
        case .emptyResponse:
            return t("The API returned an empty answer.")
        }
    }
}

/// Talks to any OpenAI compatible chat completions endpoint.
struct RemoteLLMService {
    let configuration: RemoteLLMConfiguration

    /// Streams one answer. `onToken` runs on the main actor and returns false to stop the stream early.
    func streamChat(systemPrompt: String, userText: String, onToken: @MainActor (String) -> Bool) async throws -> String {
        let request = try makeRequest(systemPrompt: systemPrompt, userText: userText, stream: true)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        try await validate(response: response, bytes: bytes)

        var fullText = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8) else { continue }
            guard let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data),
                  let token = chunk.choices?.first?.delta?.content,
                  !token.isEmpty else { continue }
            fullText += token
            if await !onToken(token) { break }
        }

        guard !fullText.isEmpty else { throw RemoteLLMError.emptyResponse }
        return fullText
    }

    /// Sends the smallest possible request to check the endpoint, the key and the model name.
    func verifyConnection() async throws {
        let request = try makeRequest(
            systemPrompt: "Reply with the single word OK.",
            userText: "ping",
            stream: false
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw RemoteLLMError.requestFailed(status: http.statusCode, message: Self.errorMessage(from: data))
        }
        guard let reply = try? JSONDecoder().decode(ChatResponse.self, from: data),
              let content = reply.choices?.first?.message?.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RemoteLLMError.emptyResponse
        }
    }

    private func makeRequest(systemPrompt: String, userText: String, stream: Bool) throws -> URLRequest {
        var request = URLRequest(url: try chatCompletionsURL())
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !configuration.apiKey.isEmpty {
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = [
            "model": configuration.modelName,
            "temperature": configuration.temperature,
            "stream": stream,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userText]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func chatCompletionsURL() throws -> URL {
        guard var components = URLComponents(string: configuration.baseURL),
              components.scheme != nil, components.host != nil else {
            throw RemoteLLMError.invalidBaseURL
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/chat/completions") {
            path += "/chat/completions"
        }
        components.path = path
        guard let url = components.url else { throw RemoteLLMError.invalidBaseURL }
        return url
    }

    private func validate(response: URLResponse, bytes: URLSession.AsyncBytes) async throws {
        guard let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) else { return }
        var data = Data()
        if let collected = try? await bytes.reduce(into: Data(), { $0.append($1) }) {
            data = collected
        }
        throw RemoteLLMError.requestFailed(status: http.statusCode, message: Self.errorMessage(from: data))
    }

    private static func errorMessage(from data: Data) -> String {
        if let payload = try? JSONDecoder().decode(APIErrorResponse.self, from: data),
           let message = payload.error?.message, !message.isEmpty {
            return message
        }
        return String(decoding: data.prefix(300), as: UTF8.self)
    }

    private struct StreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { let content: String? }
            let delta: Delta?
        }
        let choices: [Choice]?
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message?
        }
        let choices: [Choice]?
    }

    private struct APIErrorResponse: Decodable {
        struct Payload: Decodable { let message: String? }
        let error: Payload?
    }
}
