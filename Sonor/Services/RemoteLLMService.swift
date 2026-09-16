import Foundation

struct RemoteLLMConfiguration: Sendable {
    let baseURL: String
    let apiKey: String
    let modelName: String
    let temperature: Double
    /// OpenAI style reasoning effort, such as `low` or `high`.
    ///
    /// Empty means Sonor sends no field, so the service keeps its own default. Writing the
    /// effort into the model name instead only works when the endpoint parses it back out.
    let reasoningEffort: String
}

/// One finished answer from the service.
struct RemoteLLMResult: Sendable {
    let text: String
    /// True when the service stopped at the output limit before the model finished.
    let wasTruncated: Bool
}

/// What one probe of the endpoint measured.
struct RemoteLLMProbe: Sendable {
    /// Seconds until the first character arrived. This is the wait the user feels before the
    /// assistant starts writing, and reasoning happens inside it.
    let timeToFirstToken: TimeInterval
    /// Seconds until the answer finished.
    let totalTime: TimeInterval
    /// Characters written per second, counted after the first one arrived.
    let charactersPerSecond: Double
    let reply: String
}

enum RemoteLLMError: LocalizedError {
    case invalidBaseURL
    case requestFailed(status: Int, message: String)
    case emptyResponse
    case outputLimitReached

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return t("The API endpoint is not a valid URL.")
        case .requestFailed(let status, let message):
            return message.isEmpty ? "HTTP \(status)" : "HTTP \(status): \(message)"
        case .emptyResponse:
            return t("The API returned an empty answer.")
        case .outputLimitReached:
            return t("The model used the whole output limit before it wrote an answer. Lower the reasoning effort, or raise the output limit on the service.")
        }
    }
}

/// Talks to any OpenAI compatible chat completions endpoint.
struct RemoteLLMService {
    let configuration: RemoteLLMConfiguration

    /// Streams one answer. `onToken` runs on the main actor and returns false to stop the stream early.
    func streamChat(systemPrompt: String, userText: String, onToken: @MainActor (String) -> Bool) async throws -> RemoteLLMResult {
        let request = try makeRequest(systemPrompt: systemPrompt, userText: userText)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        try await validate(response: response, bytes: bytes)

        var fullText = ""
        var finishReason: String?
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8) else { continue }
            guard let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data) else { continue }
            if let reason = chunk.choices?.first?.finishReason, !reason.isEmpty {
                finishReason = reason
            }
            guard let token = chunk.choices?.first?.delta?.content,
                  !token.isEmpty else { continue }
            fullText += token
            if await !onToken(token) { break }
        }

        // A reasoning model can spend the whole output limit on thinking and never reach the
        // answer. That reads as an empty reply, so it needs its own message.
        if fullText.isEmpty {
            throw finishReason == "length" ? RemoteLLMError.outputLimitReached : RemoteLLMError.emptyResponse
        }
        return RemoteLLMResult(text: fullText, wasTruncated: finishReason == "length")
    }

    /// Checks the endpoint, the key and the model name, and times one small rewrite.
    ///
    /// The probe runs a real rewrite with the chosen settings, so the numbers match what
    /// dictation will feel like. It keeps the reasoning effort on purpose. A high effort is
    /// slow, and measuring without it would report a speed the user never sees.
    @MainActor
    func probe() async throws -> RemoteLLMProbe {
        let start = CFAbsoluteTimeGetCurrent()
        var firstTokenAt: CFAbsoluteTime?
        let result = try await streamChat(
            systemPrompt: "Rewrite the user text. Fix the grammar. Return only the rewritten sentence.",
            userText: "we was going to the store yesterday and buyed some apple"
        ) { _ in
            if firstTokenAt == nil { firstTokenAt = CFAbsoluteTimeGetCurrent() }
            return true
        }
        let end = CFAbsoluteTimeGetCurrent()
        let firstToken = firstTokenAt ?? end
        let writingTime = end - firstToken
        return RemoteLLMProbe(
            timeToFirstToken: firstToken - start,
            totalTime: end - start,
            charactersPerSecond: writingTime > 0 ? Double(result.text.count) / writingTime : 0,
            reply: result.text
        )
    }

    private func makeRequest(systemPrompt: String, userText: String) throws -> URLRequest {
        var request = URLRequest(url: try chatCompletionsURL())
        request.httpMethod = "POST"
        // This is an idle timeout. A reasoning model can think for minutes before it sends the
        // first token, and a short value cuts the answer off while the model still works.
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !configuration.apiKey.isEmpty {
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        }
        var body: [String: Any] = [
            "model": configuration.modelName,
            "temperature": configuration.temperature,
            "stream": true,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userText]
            ]
        ]
        let effort = configuration.reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
        if !effort.isEmpty {
            body["reasoning_effort"] = effort
        }
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
            let finishReason: String?

            enum CodingKeys: String, CodingKey {
                case delta
                case finishReason = "finish_reason"
            }
        }
        let choices: [Choice]?
    }

    private struct APIErrorResponse: Decodable {
        struct Payload: Decodable { let message: String? }
        let error: Payload?
    }
}
