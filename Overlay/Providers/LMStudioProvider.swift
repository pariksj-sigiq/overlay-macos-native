//
//  LMStudioProvider.swift
//  OverlayOpus
//

import Foundation

struct LMStudioProviderConfig: Codable, Equatable {
    var baseURL: URL
    var apiKey: String

    init(baseURL: URL = URL(string: "http://localhost:1234/v1")!,
         apiKey: String = "lm-studio") {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }
}

final class LMStudioProvider: LLMProvider {
    let id: String
    let displayName: String

    private let provider: OpenAIProvider

    init(id: String = "lm-studio",
         displayName: String = "LM Studio",
         config: LMStudioProviderConfig = LMStudioProviderConfig()) {
        self.id = id
        self.displayName = displayName
        provider = OpenAIProvider(id: id,
                                  displayName: displayName,
                                  config: OpenAIProviderConfig(baseURL: config.baseURL,
                                                               apiKeySecretName: "lmstudio.inline"),
                                  apiKey: config.apiKey.isEmpty ? "lm-studio" : config.apiKey)
    }

    func stream(_ req: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        provider.stream(req)
    }

    func listModels() async throws -> [String] {
        try await provider.listModels()
    }
}
