//
//  ProviderEditorView.swift
//  OverlayOpus
//

import SwiftUI

struct ProviderEditorView: View {
    var editingConfig: ProviderConfigRecord?
    var onSaved: (ProviderConfigRecord) -> Void = { _ in }

    @State private var loadedConfigID: String?
    @State private var kind: ProviderKind = .ollama
    @State private var name = "Local Ollama"
    @State private var endpoint = "http://localhost:11434"
    @State private var defaultModelID = ""
    @State private var apiVersion = "2024-02-15-preview"
    @State private var region = "us-east-1"
    @State private var apiKey = ""
    @State private var accessKeyID = ""
    @State private var secretAccessKey = ""
    @State private var sessionToken = ""
    @State private var status = ""
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Kind", selection: $kind) {
                ForEach(ProviderKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .disabled(editingConfig != nil)
            .onChange(of: kind) { oldValue, value in
                guard editingConfig == nil else { return }
                if trimmed(name).isEmpty || name == oldValue.label || name == "Local Ollama" {
                    name = value.label
                }
                applyDefaults(for: value)
            }

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)

            providerFields

            if editingConfig != nil, kind != .ollama {
                Text("Leave secret fields blank to keep the saved values.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            HStack {
                Button(editingConfig == nil ? "Save" : "Update") {
                    Task { await save() }
                }
                .disabled(isWorking)

                Button("Test") {
                    Task { await test() }
                }
                .disabled(isWorking)

                Spacer()
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
                if !status.isEmpty {
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(statusColor)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
        }
        .onAppear {
            loadEditingConfigIfNeeded()
        }
        .onChange(of: editingConfig?.id) { _, _ in
            loadEditingConfigIfNeeded(force: true)
        }
    }

    @ViewBuilder
    private var providerFields: some View {
        switch kind {
        case .ollama:
            TextField("Base URL", text: $endpoint)
                .textFieldStyle(.roundedBorder)
            TextField("Default model", text: $defaultModelID)
                .textFieldStyle(.roundedBorder)
        case .openAI:
            TextField("Base URL", text: $endpoint)
                .textFieldStyle(.roundedBorder)
            TextField("Default model", text: $defaultModelID)
                .textFieldStyle(.roundedBorder)
            SecureField(secretPlaceholder("API key"), text: $apiKey)
                .textFieldStyle(.roundedBorder)
        case .azureOpenAI:
            TextField("Endpoint, e.g. https://name.openai.azure.com", text: $endpoint)
                .textFieldStyle(.roundedBorder)
            TextField("Deployment name", text: $defaultModelID)
                .textFieldStyle(.roundedBorder)
            TextField("API version", text: $apiVersion)
                .textFieldStyle(.roundedBorder)
            SecureField(secretPlaceholder("API key"), text: $apiKey)
                .textFieldStyle(.roundedBorder)
        case .bedrock:
            TextField("Region", text: $region)
                .textFieldStyle(.roundedBorder)
            TextField("Default model ID", text: $defaultModelID)
                .textFieldStyle(.roundedBorder)
            SecureField(secretPlaceholder("Access key ID"), text: $accessKeyID)
                .textFieldStyle(.roundedBorder)
            SecureField(secretPlaceholder("Secret access key"), text: $secretAccessKey)
                .textFieldStyle(.roundedBorder)
            SecureField("Session token optional", text: $sessionToken)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var statusColor: Color {
        let lower = status.lowercased()
        if lower.contains("failed") || lower.contains("missing") || lower.contains("invalid") || lower.contains("required") {
            return .red
        }
        return .secondary
    }

    private func save() async {
        isWorking = true
        defer { isWorking = false }

        do {
            let providerID = editingConfig?.id ?? UUID().uuidString
            let createdAt = editingConfig?.createdAt ?? Date.unixSeconds
            let draft = try await makeDraft(providerID: providerID,
                                            createdAt: createdAt,
                                            persistSecrets: true)
            let saved = try await AppDatabase.shared.saveProviderConfig(draft.record)
            try await ProviderRegistry.shared.reload()
            if ProviderRegistry.shared.activeProviderID == nil {
                ProviderRegistry.shared.setActiveProviderID(saved.id)
            }
            status = editingConfig == nil ? "Saved" : "Updated"
            onSaved(saved)
        } catch {
            status = error.localizedDescription
        }
    }

    private func test() async {
        isWorking = true
        defer { isWorking = false }

        do {
            let providerID = editingConfig?.id ?? "draft-\(UUID().uuidString)"
            let createdAt = editingConfig?.createdAt ?? Date.unixSeconds
            let draft = try await makeDraft(providerID: providerID,
                                            createdAt: createdAt,
                                            persistSecrets: false)
            status = try await streamTest(provider: draft.provider, modelID: draft.defaultModelID)
        } catch {
            status = error.localizedDescription
        }
    }

    private func makeDraft(providerID: String,
                           createdAt: Int64,
                           persistSecrets: Bool) async throws -> ProviderDraft {
        let label = normalized(name) ?? kind.label
        let defaultModel = try required(defaultModelID, field: defaultModelFieldName)
        let encoder = JSONEncoder()

        switch kind {
        case .ollama:
            let url = try requiredURL(endpoint,
                                      fallback: URL(string: "http://localhost:11434"),
                                      field: "Ollama base URL")
            let config = OllamaProviderConfig(baseURL: url)
            let data = try encoder.encode(ProviderRegistryConfigEnvelope(config: config, defaultModel: defaultModel))
            let record = ProviderConfigRecord(id: providerID,
                                              kind: kind,
                                              name: label,
                                              configJSON: data,
                                              createdAt: createdAt)
            return ProviderDraft(record: record,
                                 provider: OllamaProvider(id: providerID, displayName: label, config: config),
                                 defaultModelID: defaultModel)

        case .openAI:
            let url = try requiredURL(endpoint,
                                      fallback: URL(string: "https://api.openai.com/v1"),
                                      field: "OpenAI base URL")
            let account = secretAccount(providerID: providerID,
                                        suffix: "apiKey",
                                        existing: existingOpenAIConfig()?.apiKeySecretName,
                                        hasNewSecret: normalized(apiKey) != nil)
            let apiKeyValue = try await requiredSecret(apiKey,
                                                       account: account,
                                                       field: "OpenAI API key",
                                                       persist: persistSecrets)
            let config = OpenAIProviderConfig(baseURL: url, apiKeySecretName: account)
            let data = try encoder.encode(ProviderRegistryConfigEnvelope(config: config, defaultModel: defaultModel))
            let record = ProviderConfigRecord(id: providerID,
                                              kind: kind,
                                              name: label,
                                              configJSON: data,
                                              createdAt: createdAt)
            return ProviderDraft(record: record,
                                 provider: OpenAIProvider(id: providerID,
                                                          displayName: label,
                                                          config: config,
                                                          apiKey: apiKeyValue),
                                 defaultModelID: defaultModel)

        case .azureOpenAI:
            let url = try requiredURL(endpoint, fallback: nil, field: "Azure endpoint")
            let deployment = defaultModel
            let version = try required(apiVersion, field: "Azure API version")
            let account = secretAccount(providerID: providerID,
                                        suffix: "apiKey",
                                        existing: existingAzureConfig()?.apiKeySecretName,
                                        hasNewSecret: normalized(apiKey) != nil)
            let apiKeyValue = try await requiredSecret(apiKey,
                                                       account: account,
                                                       field: "Azure API key",
                                                       persist: persistSecrets)
            let config = AzureOpenAIProviderConfig(endpoint: url,
                                                   deploymentName: deployment,
                                                   apiVersion: version,
                                                   apiKeySecretName: account)
            let data = try encoder.encode(ProviderRegistryConfigEnvelope(config: config, defaultModel: deployment))
            let record = ProviderConfigRecord(id: providerID,
                                              kind: kind,
                                              name: label,
                                              configJSON: data,
                                              createdAt: createdAt)
            return ProviderDraft(record: record,
                                 provider: AzureOpenAIProvider(id: providerID,
                                                               displayName: label,
                                                               config: config,
                                                               apiKey: apiKeyValue),
                                 defaultModelID: deployment)

        case .bedrock:
            let bedrockRegion = try required(region, field: "Bedrock region")
            let existing = existingBedrockConfig()
            let accessAccount = secretAccount(providerID: providerID,
                                              suffix: "accessKeyID",
                                              existing: existing?.accessKeyIDSecretName,
                                              hasNewSecret: normalized(accessKeyID) != nil)
            let secretKeyAccount = secretAccount(providerID: providerID,
                                                 suffix: "secretAccessKey",
                                                 existing: existing?.secretAccessKeySecretName,
                                                 hasNewSecret: normalized(secretAccessKey) != nil)
            let tokenAccount = secretAccount(providerID: providerID,
                                             suffix: "sessionToken",
                                             existing: existing?.sessionTokenSecretName,
                                             hasNewSecret: normalized(sessionToken) != nil)
            let accessValue = try await requiredSecret(accessKeyID,
                                                       account: accessAccount,
                                                       field: "Bedrock access key ID",
                                                       persist: persistSecrets)
            let secretValue = try await requiredSecret(secretAccessKey,
                                                       account: secretKeyAccount,
                                                       field: "Bedrock secret access key",
                                                       persist: persistSecrets)
            let tokenValue = try await optionalSecret(sessionToken,
                                                      account: tokenAccount,
                                                      persist: persistSecrets)
            let config = BedrockProviderConfig(region: bedrockRegion,
                                               defaultModelID: defaultModel,
                                               accessKeyIDSecretName: accessAccount,
                                               secretAccessKeySecretName: secretKeyAccount,
                                               sessionTokenSecretName: tokenValue == nil ? nil : tokenAccount)
            let data = try encoder.encode(ProviderRegistryConfigEnvelope(config: config, defaultModel: defaultModel))
            let credentials = SigV4Credentials(accessKeyID: accessValue,
                                               secretAccessKey: secretValue,
                                               sessionToken: tokenValue)
            let record = ProviderConfigRecord(id: providerID,
                                              kind: kind,
                                              name: label,
                                              configJSON: data,
                                              createdAt: createdAt)
            return ProviderDraft(record: record,
                                 provider: BedrockProvider(id: providerID,
                                                           displayName: label,
                                                           config: config,
                                                           credentials: credentials),
                                 defaultModelID: defaultModel)
        }
    }

    private func streamTest(provider: any LLMProvider, modelID: String) async throws -> String {
        let request = LLMRequest(systemPrompt: "You are a connection test. Reply with OK.",
                                 userPrompt: "Reply with OK.",
                                 modelID: modelID,
                                 temperature: 0,
                                 maxTokens: 8)
        var received = ""
        for try await event in provider.stream(request) {
            switch event {
            case .token(let token):
                received += token
            case .done:
                return received.isEmpty ? "Connected" : "Stream test connected"
            case .error(let error):
                throw error
            }
        }
        return received.isEmpty ? "Connected" : "Stream test connected"
    }

    private func loadEditingConfigIfNeeded(force: Bool = false) {
        guard force || loadedConfigID != editingConfig?.id else { return }
        loadedConfigID = editingConfig?.id
        status = ""
        apiKey = ""
        accessKeyID = ""
        secretAccessKey = ""
        sessionToken = ""

        guard let editingConfig else {
            kind = .ollama
            name = "Local Ollama"
            applyDefaults(for: .ollama)
            return
        }

        kind = editingConfig.kind
        name = editingConfig.name
        defaultModelID = ProviderRegistry.defaultModelID(for: editingConfig) ?? ""

        switch editingConfig.kind {
        case .ollama:
            if let config = try? ProviderRegistry.decodeConfig(OllamaProviderConfig.self, from: editingConfig.configJSON) {
                endpoint = config.baseURL.absoluteString
            }
        case .openAI:
            if let config = try? ProviderRegistry.decodeConfig(OpenAIProviderConfig.self, from: editingConfig.configJSON) {
                endpoint = config.baseURL?.absoluteString ?? "https://api.openai.com/v1"
            }
        case .azureOpenAI:
            if let config = try? ProviderRegistry.decodeConfig(AzureOpenAIProviderConfig.self, from: editingConfig.configJSON) {
                endpoint = config.endpoint.absoluteString
                apiVersion = config.apiVersion
                defaultModelID = ProviderRegistry.defaultModelID(for: editingConfig) ?? config.deploymentName
            }
        case .bedrock:
            if let config = try? ProviderRegistry.decodeConfig(BedrockProviderConfig.self, from: editingConfig.configJSON) {
                region = config.region
                defaultModelID = ProviderRegistry.defaultModelID(for: editingConfig) ?? config.defaultModelID ?? ""
            }
        }
    }

    private var defaultModelFieldName: String {
        switch kind {
        case .azureOpenAI:
            return "Azure deployment name"
        case .bedrock:
            return "Bedrock default model ID"
        case .ollama, .openAI:
            return "\(kind.label) default model"
        }
    }

    private func applyDefaults(for kind: ProviderKind) {
        switch kind {
        case .ollama:
            endpoint = "http://localhost:11434"
        case .openAI:
            endpoint = "https://api.openai.com/v1"
        case .azureOpenAI, .bedrock:
            endpoint = ""
        }

        apiVersion = "2024-02-15-preview"
        region = "us-east-1"
        defaultModelID = ""
    }

    private func required(_ value: String, field: String) throws -> String {
        guard let value = normalized(value) else {
            throw LLMProviderError.invalidConfiguration("\(field) is required")
        }
        return value
    }

    private func requiredURL(_ value: String, fallback: URL?, field: String) throws -> URL {
        let candidate = normalized(value)
        if candidate == nil, let fallback {
            return fallback
        }
        guard let raw = candidate,
              let url = URL(string: raw),
              let scheme = url.scheme,
              !scheme.isEmpty else {
            throw LLMProviderError.invalidConfiguration("\(field) must be a valid URL")
        }
        return url
    }

    private func requiredSecret(_ value: String,
                                account: String,
                                field: String,
                                persist: Bool) async throws -> String {
        if let value = normalized(value) {
            if persist {
                try KeychainStore.shared.set(value, account: account)
            }
            return value
        }

        if let existing = try await KeychainStore.shared.string(for: account),
           !existing.isEmpty {
            return existing
        }

        throw LLMProviderError.invalidConfiguration("\(field) is required")
    }

    private func optionalSecret(_ value: String,
                                account: String,
                                persist: Bool) async throws -> String? {
        if let value = normalized(value) {
            if persist {
                try KeychainStore.shared.set(value, account: account)
            }
            return value
        }

        let existing = try await KeychainStore.shared.string(for: account)
        return existing?.isEmpty == true ? nil : existing
    }

    private func secretAccount(providerID: String,
                               suffix: String,
                               existing: String?,
                               hasNewSecret: Bool) -> String {
        if !hasNewSecret, let existing = normalized(existing) {
            return existing
        }
        return "provider:\(providerID):\(suffix)"
    }

    private func existingOpenAIConfig() -> OpenAIProviderConfig? {
        guard let editingConfig, editingConfig.kind == .openAI else { return nil }
        return try? ProviderRegistry.decodeConfig(OpenAIProviderConfig.self, from: editingConfig.configJSON)
    }

    private func existingAzureConfig() -> AzureOpenAIProviderConfig? {
        guard let editingConfig, editingConfig.kind == .azureOpenAI else { return nil }
        return try? ProviderRegistry.decodeConfig(AzureOpenAIProviderConfig.self, from: editingConfig.configJSON)
    }

    private func existingBedrockConfig() -> BedrockProviderConfig? {
        guard let editingConfig, editingConfig.kind == .bedrock else { return nil }
        return try? ProviderRegistry.decodeConfig(BedrockProviderConfig.self, from: editingConfig.configJSON)
    }

    private func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func secretPlaceholder(_ label: String) -> String {
        editingConfig == nil ? label : "\(label), leave blank to keep existing"
    }
}

private struct ProviderDraft {
    let record: ProviderConfigRecord
    let provider: any LLMProvider
    let defaultModelID: String
}
