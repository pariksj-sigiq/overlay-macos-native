//
//  ProviderRegistry.swift
//  OverlayOpus
//

import Combine
import Foundation

struct ProviderRegistryConfigEnvelope<Config: Codable>: Codable {
    let config: Config
    let defaultModel: String?
}

private struct ProviderRegistryConfigMetadata: Decodable {
    let defaultModel: String?
}

@MainActor
final class ProviderRegistry: ObservableObject {
    static let shared = ProviderRegistry()

    @Published private(set) var configs: [ProviderConfigRecord] = []
    @Published private(set) var providers: [any LLMProvider] = []
    @Published private(set) var activeProviderID: String?

    private static let activeProviderDefaultsKey = "overlay.activeProviderID"
    private static let decoder = JSONDecoder()
    private static let userDefaults = UserDefaults.standard

    private init() {}

    func reload() async throws {
        let records = try await AppDatabase.shared.fetchProviderConfigs()

        var loaded: [any LLMProvider] = []
        for record in records {
            if let provider = try? await makeProvider(from: record) {
                loaded.append(provider)
            }
        }

        configs = records
        providers = loaded
        reconcileActiveProvider(with: records)
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

    func setActiveProviderID(_ id: String?) {
        let normalized = id?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized, !normalized.isEmpty else {
            activeProviderID = nil
            Self.userDefaults.removeObject(forKey: Self.activeProviderDefaultsKey)
            return
        }

        guard configs.contains(where: { $0.id == normalized }) else {
            return
        }

        activeProviderID = normalized
        Self.userDefaults.set(normalized, forKey: Self.activeProviderDefaultsKey)
    }

    func defaultModelID(for providerID: String?) -> String? {
        guard let providerID,
              let record = configs.first(where: { $0.id == providerID }) else {
            return nil
        }
        return Self.defaultModelID(for: record)
    }

    func deleteProviderConfig(id: String) async throws {
        var record = configs.first(where: { $0.id == id })
        if record == nil {
            let records = try await AppDatabase.shared.fetchProviderConfigs()
            record = records.first(where: { $0.id == id })
        }

        if let record {
            try Self.deleteSecrets(for: record)
        }

        try await AppDatabase.shared.deleteProviderConfig(id: id)
        if activeProviderID == id {
            activeProviderID = nil
            Self.userDefaults.removeObject(forKey: Self.activeProviderDefaultsKey)
        }
        try await reload()
    }

    func deleteSecrets(for record: ProviderConfigRecord) throws {
        try Self.deleteSecrets(for: record)
    }

    static func decodeConfig<Config: Codable>(_ type: Config.Type, from data: Data) throws -> Config {
        do {
            return try decoder.decode(Config.self, from: data)
        } catch {
            if let envelope = try? decoder.decode(ProviderRegistryConfigEnvelope<Config>.self, from: data) {
                return envelope.config
            }
            throw LLMProviderError.invalidConfiguration("Could not decode \(type)")
        }
    }

    static func defaultModelID(for record: ProviderConfigRecord) -> String? {
        if let metadata = try? decoder.decode(ProviderRegistryConfigMetadata.self, from: record.configJSON),
           let model = normalized(metadata.defaultModel) {
            return model
        }

        switch record.kind {
        case .azureOpenAI:
            guard let config = try? decodeConfig(AzureOpenAIProviderConfig.self, from: record.configJSON) else { return nil }
            return normalized(config.deploymentName)
        case .bedrock:
            guard let config = try? decodeConfig(BedrockProviderConfig.self, from: record.configJSON) else { return nil }
            return normalized(config.defaultModelID)
        case .ollama:
            guard let config = try? decodeConfig(OllamaProviderConfig.self, from: record.configJSON) else { return nil }
            return normalized(config.defaultModelID)
        case .openAI:
            guard let config = try? decodeConfig(OpenAIProviderConfig.self, from: record.configJSON) else { return nil }
            return normalized(config.defaultModelID)
        }
    }

    private func makeProvider(from record: ProviderConfigRecord) async throws -> (any LLMProvider)? {
        switch record.kind {
        case .openAI:
            let config = try Self.decodeConfig(OpenAIProviderConfig.self, from: record.configJSON)
            let apiKey = try await secret(config.apiKeySecretName)
            return OpenAIProvider(id: record.id, displayName: record.name, config: config, apiKey: apiKey)

        case .azureOpenAI:
            let config = try Self.decodeConfig(AzureOpenAIProviderConfig.self, from: record.configJSON)
            let apiKey = try await secret(config.apiKeySecretName)
            return AzureOpenAIProvider(id: record.id, displayName: record.name, config: config, apiKey: apiKey)

        case .ollama:
            let config = try Self.decodeConfig(OllamaProviderConfig.self, from: record.configJSON)
            return OllamaProvider(id: record.id, displayName: record.name, config: config)

        case .bedrock:
            let config = try Self.decodeConfig(BedrockProviderConfig.self, from: record.configJSON)
            let accessKeyID = try await secret(config.accessKeyIDSecretName)
            let secretAccessKey = try await secret(config.secretAccessKeySecretName)
            let sessionToken = try await optionalSecret(config.sessionTokenSecretName)
            let credentials = SigV4Credentials(accessKeyID: accessKeyID,
                                               secretAccessKey: secretAccessKey,
                                               sessionToken: sessionToken)
            return BedrockProvider(id: record.id, displayName: record.name, config: config, credentials: credentials)
        }
    }

    private func reconcileActiveProvider(with records: [ProviderConfigRecord]) {
        let recordIDs = Set(records.map(\.id))

        if let persisted = Self.userDefaults.string(forKey: Self.activeProviderDefaultsKey),
           recordIDs.contains(persisted) {
            activeProviderID = persisted
            return
        }

        if let current = activeProviderID, recordIDs.contains(current) {
            Self.userDefaults.set(current, forKey: Self.activeProviderDefaultsKey)
            return
        }

        activeProviderID = records.first?.id
        if let activeProviderID {
            Self.userDefaults.set(activeProviderID, forKey: Self.activeProviderDefaultsKey)
        } else {
            Self.userDefaults.removeObject(forKey: Self.activeProviderDefaultsKey)
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

    private static func deleteSecrets(for record: ProviderConfigRecord) throws {
        try KeychainStore.shared.delete(accounts: secretAccounts(for: record))
    }

    private static func secretAccounts(for record: ProviderConfigRecord) -> [String] {
        switch record.kind {
        case .openAI:
            guard let config = try? decodeConfig(OpenAIProviderConfig.self, from: record.configJSON) else {
                return ["provider:\(record.id):apiKey"]
            }
            return [config.apiKeySecretName]
        case .azureOpenAI:
            guard let config = try? decodeConfig(AzureOpenAIProviderConfig.self, from: record.configJSON) else {
                return ["provider:\(record.id):apiKey"]
            }
            return [config.apiKeySecretName]
        case .ollama:
            return []
        case .bedrock:
            guard let config = try? decodeConfig(BedrockProviderConfig.self, from: record.configJSON) else {
                return [
                    "provider:\(record.id):accessKeyID",
                    "provider:\(record.id):secretAccessKey",
                    "provider:\(record.id):sessionToken"
                ]
            }
            return [
                config.accessKeyIDSecretName,
                config.secretAccessKeySecretName,
                config.sessionTokenSecretName
            ].compactMap { normalized($0) }
        }
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
