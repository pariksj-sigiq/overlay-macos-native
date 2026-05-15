//
//  OllamaProvider.swift
//  OverlayOpus
//

import Foundation

struct OllamaProviderConfig: Codable, Equatable {
    var baseURL: URL
    var defaultModelID: String?

    init(baseURL: URL = Self.defaultBaseURL(),
         defaultModelID: String? = nil) {
        self.baseURL = baseURL
        self.defaultModelID = defaultModelID
    }

    private static func defaultBaseURL() -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "localhost"
        components.port = 11434
        return components.url ?? URL(fileURLWithPath: "/")
    }
}

final class OllamaProvider: LLMProvider {
    let id: String
    let displayName: String

    private let config: OllamaProviderConfig
    private let session: URLSession

    init(id: String = "ollama",
         displayName: String = "Ollama",
         config: OllamaProviderConfig = OllamaProviderConfig(),
         session: URLSession = .shared) {
        self.id = id
        self.displayName = displayName
        self.config = config
        self.session = session
    }

    func stream(_ req: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let url = config.baseURL
                        .appendingPathComponent("api")
                        .appendingPathComponent("chat")
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: [
                        "model": req.model,
                        "messages": req.messages.map { ["role": $0.role.rawValue, "content": $0.content] },
                        "options": [
                            "temperature": req.temperature,
                            "num_predict": req.maxTokens
                        ],
                        "stream": true
                    ])

                    let (bytes, response) = try await session.bytes(for: request)
                    try OpenAIProvider.validate(response: response, bytes: bytes)

                    var parser = NDJSONParser()
                    for try await byte in bytes {
                        for line in try parser.feed(Data([byte])) {
                            let event = try Self.parseLine(line)
                            continuation.yield(event)
                            if case .done = event {
                                continuation.finish()
                                return
                            }
                        }
                    }

                    for line in parser.finish() {
                        let event = try Self.parseLine(line)
                        continuation.yield(event)
                        if case .done = event {
                            continuation.finish()
                            return
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
        let url = config.baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("tags")
        let request = URLRequest(url: url)
        let (data, response) = try await session.data(for: request)
        try OpenAIProvider.validate(response: response, data: data)

        let json = try JSONSerialization.jsonObject(with: data)
        guard let root = json as? [String: Any],
              let models = root["models"] as? [[String: Any]] else {
            throw LLMProviderError.invalidResponse("Ollama tags response was not an object with models")
        }

        return models.compactMap { $0["name"] as? String }.sorted()
    }

    private static func parseLine(_ line: String) throws -> LLMEvent {
        guard let data = line.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMProviderError.invalidResponse("Ollama returned invalid JSON line")
        }

        if let error = root["error"] as? String {
            throw LLMProviderError.invalidResponse(error)
        }
        if let done = root["done"] as? Bool, done {
            return .done
        }
        if let message = root["message"] as? [String: Any],
           let content = message["content"] as? String {
            return .token(content)
        }
        return .token("")
    }
}

private struct NDJSONParser {
    private var buffer = ""

    mutating func feed(_ data: Data) throws -> [String] {
        guard let chunk = String(data: data, encoding: .utf8) else {
            throw LLMProviderError.invalidResponse("NDJSON stream contained non-UTF8 data")
        }

        buffer += chunk
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeSubrange(buffer.startIndex...newline)
            if !line.isEmpty {
                lines.append(line)
            }
        }
        return lines
    }

    mutating func finish() -> [String] {
        let line = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return line.isEmpty ? [] : [line]
    }
}
