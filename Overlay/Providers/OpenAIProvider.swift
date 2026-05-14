//
//  OpenAIProvider.swift
//  OverlayOpus
//

import Foundation

struct OpenAIProviderConfig: Codable, Equatable {
    var baseURL: URL?
    var apiKeySecretName: String

    init(baseURL: URL? = URL(string: "https://api.openai.com/v1"),
         apiKeySecretName: String = "openai.apiKey") {
        self.baseURL = baseURL
        self.apiKeySecretName = apiKeySecretName
    }
}

final class OpenAIProvider: LLMProvider {
    let id: String
    let displayName: String

    private let config: OpenAIProviderConfig
    private let apiKey: String
    private let session: URLSession

    init(id: String = "openai",
         displayName: String = "OpenAI",
         config: OpenAIProviderConfig,
         apiKey: String,
         session: URLSession = .shared) {
        self.id = id
        self.displayName = displayName
        self.config = config
        self.apiKey = apiKey
        self.session = session
    }

    func stream(_ req: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let request = try makeChatRequest(req)
                    let (bytes, response) = try await session.bytes(for: request)
                    try Self.validate(response: response, bytes: bytes)

                    var parser = SSEParser()
                    for try await byte in bytes {
                        for event in try parser.feed(Data([byte])) {
                            if let token = Self.extractChatToken(from: event), !token.isEmpty {
                                continuation.yield(.token(token))
                            }
                        }
                    }

                    for event in parser.finish() {
                        if let token = Self.extractChatToken(from: event), !token.isEmpty {
                            continuation.yield(.token(token))
                        }
                    }

                    continuation.yield(.done)
                    continuation.finish()
                } catch {
                    continuation.yield(.error(error))
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func listModels() async throws -> [String] {
        guard let baseURL = config.baseURL else {
            throw LLMProviderError.invalidConfiguration("OpenAI baseURL is missing")
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)

        let json = try JSONSerialization.jsonObject(with: data)
        guard let root = json as? [String: Any],
              let models = root["data"] as? [[String: Any]] else {
            throw LLMProviderError.invalidResponse("OpenAI models response was not an object with data")
        }

        return models.compactMap { $0["id"] as? String }.sorted()
    }

    private func makeChatRequest(_ req: LLMRequest) throws -> URLRequest {
        guard let baseURL = config.baseURL else {
            throw LLMProviderError.invalidConfiguration("OpenAI baseURL is missing")
        }

        let url = baseURL
            .appendingPathComponent("chat")
            .appendingPathComponent("completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": req.model,
            "messages": req.messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            "max_tokens": req.maxTokens,
            "temperature": req.temperature,
            "stream": true
        ])
        return request
    }

    static func extractChatToken(from event: String) -> String? {
        guard let data = event.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let first = choices.first else {
            return nil
        }

        if let delta = first["delta"] as? [String: Any] {
            return delta["content"] as? String
        }
        if let message = first["message"] as? [String: Any] {
            return message["content"] as? String
        }
        return nil
    }

    static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw LLMProviderError.invalidResponse("Response was not HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LLMProviderError.httpStatus(http.statusCode, body)
        }
    }

    static func validate(response: URLResponse, bytes: URLSession.AsyncBytes) throws {
        guard let http = response as? HTTPURLResponse else {
            throw LLMProviderError.invalidResponse("Response was not HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMProviderError.httpStatus(http.statusCode, "streaming response body unavailable")
        }
    }
}
