//
//  ProviderRegistry.swift
//  OverlayOpus
//

import Combine
import Foundation

struct ProviderRegistryConfigEnvelope<Config: Decodable>: Decodable {
    let config: Config
}

@MainActor
final class ProviderRegistry: ObservableObject {
    static let shared = ProviderRegistry()

    @Published private(set) var configs: [ProviderConfigRecord] = []
    @Published private(set) var providers: [any LLMProvider] = []
    @Published private(set) var activeProviderID: String?

    private let decoder = JSONDecoder()

    private init() {}

    func reload() async throws {
        let records = try await AppDatabase.shared.fetchProviderConfigs()

        var loaded: [any LLMProvider] = []
        for record in records {
            if let provider = try await makeProvider(from: record) {
                loaded.append(provider)
            }
        }

        configs = records
        providers = loaded
        activeProviderID = activeProviderID ?? records.first?.id
    }

    func provider(id: String? = nil) throws -> any LLMProvider {
        let resolvedID = id ?? activeProviderID
        guard let resolvedID else {
            throw LLMProviderError.invalidConfiguration("No active LLM provider is configured")
        }

        guard let provider = providers.first(where: { $0.id == resolvedID }) else {
            throw LLMProviderError.invalidConfiguration("No loaded LLM provider matches id \(resolvedID)")
        }
        return provider
    }

    private func makeProvider(from record: ProviderConfigRecord) async throws -> (any LLMProvider)? {
        switch record.kind {
        case .openAI:
            let config = try decode(OpenAIProviderConfig.self, from: record.configJSON)
            let apiKey = try await secret(config.apiKeySecretName)
            return OpenAIProvider(id: record.id, displayName: record.name, config: config, apiKey: apiKey)

        case .azureOpenAI:
            let config = try decode(AzureOpenAIProviderConfig.self, from: record.configJSON)
            let apiKey = try await secret(config.apiKeySecretName)
            return AzureOpenAIProvider(id: record.id, displayName: record.name, config: config, apiKey: apiKey)

        case .ollama:
            let config = try decode(OllamaProviderConfig.self, from: record.configJSON)
            return OllamaProvider(id: record.id, displayName: record.name, config: config)

        case .bedrock:
            let config = try decode(BedrockProviderConfig.self, from: record.configJSON)
            let accessKeyID = try await secret(config.accessKeyIDSecretName)
            let secretAccessKey = try await secret(config.secretAccessKeySecretName)
            let sessionToken = try await optionalSecret(config.sessionTokenSecretName)
            let credentials = SigV4Credentials(accessKeyID: accessKeyID,
                                               secretAccessKey: secretAccessKey,
                                               sessionToken: sessionToken)
            return BedrockProvider(id: record.id, displayName: record.name, config: config, credentials: credentials)
        }
    }

    private func decode<Config: Decodable>(_ type: Config.Type, from data: Data) throws -> Config {
        do {
            return try decoder.decode(Config.self, from: data)
        } catch {
            if let envelope = try? decoder.decode(ProviderRegistryConfigEnvelope<Config>.self, from: data) {
                return envelope.config
            }
            throw LLMProviderError.invalidConfiguration("Could not decode \(type)")
        }
    }

    private func secret(_ name: String) async throws -> String {
        guard let value = try await KeychainStore.shared.string(for: name), !value.isEmpty else {
            throw LLMProviderError.missingSecret(name)
        }
        return value
    }

    private func optionalSecret(_ name: String?) async throws -> String? {
        guard let name, !name.isEmpty else { return nil }
        let value = try await KeychainStore.shared.string(for: name)
        return value?.isEmpty == true ? nil : value
    }
}
