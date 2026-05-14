//
//  ProviderEditorView.swift
//  OverlayOpus
//

import SwiftUI

struct ProviderEditorView: View {
    @State private var kind: ProviderKind = .ollama
    @State private var name = "Local Ollama"
    @State private var endpoint = "http://localhost:11434"
    @State private var deploymentOrModel = ""
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
            .onChange(of: kind) { _, value in
                if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name == "Local Ollama" {
                    name = value.label
                }
            }

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)

            switch kind {
            case .ollama:
                TextField("Base URL", text: $endpoint)
                    .textFieldStyle(.roundedBorder)
                TextField("Default model", text: $deploymentOrModel)
                    .textFieldStyle(.roundedBorder)
            case .openAI:
                TextField("Base URL", text: $endpoint)
                    .textFieldStyle(.roundedBorder)
                SecureField("API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
            case .azureOpenAI:
                TextField("Endpoint, e.g. https://name.openai.azure.com", text: $endpoint)
                    .textFieldStyle(.roundedBorder)
                TextField("Deployment name", text: $deploymentOrModel)
                    .textFieldStyle(.roundedBorder)
                TextField("API version", text: $apiVersion)
                    .textFieldStyle(.roundedBorder)
                SecureField("API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
            case .bedrock:
                TextField("Region", text: $region)
                    .textFieldStyle(.roundedBorder)
                SecureField("Access key ID", text: $accessKeyID)
                    .textFieldStyle(.roundedBorder)
                SecureField("Secret access key", text: $secretAccessKey)
                    .textFieldStyle(.roundedBorder)
                SecureField("Session token", text: $sessionToken)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("Save") {
                    Task { await save() }
                }
                .disabled(isWorking)

                Button("Test") {
                    Task { await test() }
                }
                .disabled(isWorking)

                Spacer()
                if !status.isEmpty {
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private func save() async {
        isWorking = true
        defer { isWorking = false }

        do {
            let id = UUID().uuidString
            let data = try configData(providerID: id)
            let label = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? kind.label : name
            let record = ProviderConfigRecord(id: id, kind: kind, name: label, configJSON: data)
            _ = try await AppDatabase.shared.saveProviderConfig(record)
            try await ProviderRegistry.shared.reload()
            status = "Saved"
        } catch {
            status = error.localizedDescription
        }
    }

    private func test() async {
        isWorking = true
        defer { isWorking = false }

        do {
            try await ProviderRegistry.shared.reload()
            let provider = try await ProviderRegistry.shared.provider()
            let models = try await provider.listModels()
            status = models.first.map { "Connected: \($0)" } ?? "Connected"
        } catch {
            status = error.localizedDescription
        }
    }

    private func configData(providerID: String) throws -> Data {
        let encoder = JSONEncoder()
        switch kind {
        case .ollama:
            let url = URL(string: endpoint).flatMap { $0.scheme == nil ? nil : $0 } ?? URL(string: "http://localhost:11434")
            return try encoder.encode(OllamaProviderConfig(baseURL: url ?? URL(fileURLWithPath: "/")))
        case .openAI:
            let account = "provider:\(providerID):apiKey"
            if !apiKey.isEmpty {
                try KeychainStore.shared.set(apiKey, account: account)
            }
            let url = endpoint.isEmpty ? URL(string: "https://api.openai.com/v1") : URL(string: endpoint)
            return try encoder.encode(OpenAIProviderConfig(baseURL: url, apiKeySecretName: account))
        case .azureOpenAI:
            guard let url = URL(string: endpoint), !deploymentOrModel.isEmpty else {
                throw LLMProviderError.invalidConfiguration("Azure endpoint and deployment are required")
            }
            let account = "provider:\(providerID):apiKey"
            if !apiKey.isEmpty {
                try KeychainStore.shared.set(apiKey, account: account)
            }
            return try encoder.encode(AzureOpenAIProviderConfig(endpoint: url,
                                                               deploymentName: deploymentOrModel,
                                                               apiVersion: apiVersion,
                                                               apiKeySecretName: account))
        case .bedrock:
            let accessAccount = "provider:\(providerID):accessKeyID"
            let secretAccount = "provider:\(providerID):secretAccessKey"
            let tokenAccount = "provider:\(providerID):sessionToken"
            if !accessKeyID.isEmpty {
                try KeychainStore.shared.set(accessKeyID, account: accessAccount)
            }
            if !secretAccessKey.isEmpty {
                try KeychainStore.shared.set(secretAccessKey, account: secretAccount)
            }
            if !sessionToken.isEmpty {
                try KeychainStore.shared.set(sessionToken, account: tokenAccount)
            }
            return try encoder.encode(BedrockProviderConfig(region: region,
                                                            accessKeyIDSecretName: accessAccount,
                                                            secretAccessKeySecretName: secretAccount,
                                                            sessionTokenSecretName: sessionToken.isEmpty ? nil : tokenAccount))
        }
    }
}
