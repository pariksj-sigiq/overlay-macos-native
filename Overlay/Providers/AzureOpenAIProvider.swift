//
//  AzureOpenAIProvider.swift
//  OverlayOpus
//

import Foundation

struct AzureOpenAIProviderConfig: Codable, Equatable {
    var endpoint: URL
    var deploymentName: String
    var apiVersion: String
    var apiKeySecretName: String

    init(endpoint: URL,
         deploymentName: String,
         apiVersion: String = "2024-02-15-preview",
         apiKeySecretName: String = "azureOpenAI.apiKey") {
        self.endpoint = endpoint
        self.deploymentName = deploymentName
        self.apiVersion = apiVersion
        self.apiKeySecretName = apiKeySecretName
    }
}

final class AzureOpenAIProvider: LLMProvider {
    let id: String
    let displayName: String

    private let config: AzureOpenAIProviderConfig
    private let apiKey: String
    private let session: URLSession

    init(id: String = "azure-openai",
         displayName: String = "Azure OpenAI",
         config: AzureOpenAIProviderConfig,
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
                    try OpenAIProvider.validate(response: response, bytes: bytes)

                    var parser = SSEParser()
                    for try await byte in bytes {
                        for event in try parser.feed(Data([byte])) {
                            if let token = OpenAIProvider.extractChatToken(from: event), !token.isEmpty {
                                continuation.yield(.token(token))
                            }
                        }
                    }

                    for event in parser.finish() {
                        if let token = OpenAIProvider.extractChatToken(from: event), !token.isEmpty {
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
        [config.deploymentName]
    }

    private func makeChatRequest(_ req: LLMRequest) throws -> URLRequest {
        var components = URLComponents(url: config.endpoint, resolvingAgainstBaseURL: false)
        let path = "/openai/deployments/\(config.deploymentName)/chat/completions"
        let basePath = config.endpoint.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components?.path = basePath.isEmpty ? path : "/\(basePath)\(path)"
        components?.queryItems = [URLQueryItem(name: "api-version", value: config.apiVersion)]

        guard let url = components?.url else {
            throw LLMProviderError.invalidURL(config.endpoint.absoluteString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "messages": req.messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            "max_tokens": req.maxTokens,
            "temperature": req.temperature,
            "stream": true
        ])
        return request
    }
}
