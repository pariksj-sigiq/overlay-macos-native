//
//  LLMProvider.swift
//  OverlayOpus
//

import Foundation

struct LLMMessage: Codable, Equatable {
    let role: Role
    let content: String

    enum Role: String, Codable {
        case system
        case user
        case assistant
    }
}

struct LLMRequest: Codable, Equatable {
    let messages: [LLMMessage]
    let model: String
    let maxTokens: Int
    let temperature: Double

    init(messages: [LLMMessage],
         model: String,
         maxTokens: Int,
         temperature: Double) {
        self.messages = messages
        self.model = model
        self.maxTokens = maxTokens
        self.temperature = temperature
    }

    init(systemPrompt: String,
         userPrompt: String,
         modelID: String,
         temperature: Double,
         maxTokens: Int) {
        self.messages = [
            LLMMessage(role: .system, content: systemPrompt),
            LLMMessage(role: .user, content: userPrompt)
        ]
        self.model = modelID
        self.maxTokens = maxTokens
        self.temperature = temperature
    }
}

enum LLMEvent {
    case token(String)
    case done
    case error(Error)
}

protocol LLMProvider {
    var id: String { get }
    var displayName: String { get }

    func stream(_ req: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error>
    func listModels() async throws -> [String]
}

enum LLMProviderError: LocalizedError {
    case invalidConfiguration(String)
    case missingSecret(String)
    case invalidURL(String)
    case httpStatus(Int, String)
    case invalidResponse(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            return "Invalid provider configuration: \(message)"
        case .missingSecret(let key):
            return "Missing provider secret: \(key)"
        case .invalidURL(let value):
            return "Invalid provider URL: \(value)"
        case .httpStatus(let status, let body):
            return "Provider request failed with HTTP \(status): \(body)"
        case .invalidResponse(let message):
            return "Invalid provider response: \(message)"
        case .unsupported(let message):
            return "Unsupported provider operation: \(message)"
        }
    }
}
