//
//  BedrockProvider.swift
//  OverlayOpus
//

import Foundation

struct BedrockProviderConfig: Codable, Equatable {
    var region: String
    var accessKeyIDSecretName: String
    var secretAccessKeySecretName: String
    var sessionTokenSecretName: String?

    init(region: String,
         accessKeyIDSecretName: String = "bedrock.accessKeyID",
         secretAccessKeySecretName: String = "bedrock.secretAccessKey",
         sessionTokenSecretName: String? = "bedrock.sessionToken") {
        self.region = region
        self.accessKeyIDSecretName = accessKeyIDSecretName
        self.secretAccessKeySecretName = secretAccessKeySecretName
        self.sessionTokenSecretName = sessionTokenSecretName
    }
}

final class BedrockProvider: LLMProvider {
    let id: String
    let displayName: String

    private let config: BedrockProviderConfig
    private let credentials: SigV4Credentials
    private let session: URLSession

    init(id: String = "bedrock",
         displayName: String = "Amazon Bedrock",
         config: BedrockProviderConfig,
         credentials: SigV4Credentials,
         session: URLSession = .shared) {
        self.id = id
        self.displayName = displayName
        self.config = config
        self.credentials = credentials
        self.session = session
    }

    func stream(_ req: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let body = try requestBody(for: req)
                    let request = try signedRequest(modelID: req.model, body: body)
                    let (bytes, response) = try await session.bytes(for: request)
                    try OpenAIProvider.validate(response: response, bytes: bytes)

                    for try await _ in bytes {
                        throw LLMProviderError.unsupported("Bedrock response-stream binary event parsing is not implemented yet")
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
        throw LLMProviderError.unsupported("Bedrock model listing is not implemented in the local provider scaffold")
    }

    private func signedRequest(modelID: String, body: Data) throws -> URLRequest {
        guard let encodedModel = modelID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://bedrock-runtime.\(config.region).amazonaws.com/model/\(encodedModel)/invoke-with-response-stream") else {
            throw LLMProviderError.invalidURL(modelID)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/vnd.amazon.eventstream", forHTTPHeaderField: "Accept")
        request.setValue("application/vnd.amazon.eventstream", forHTTPHeaderField: "X-Amzn-Bedrock-Accept")

        let signer = SigV4(service: "bedrock", region: config.region, credentials: credentials)
        return try signer.sign(request, body: body)
    }

    private func requestBody(for req: LLMRequest) throws -> Data {
        let lowerModel = req.model.lowercased()
        if lowerModel.contains("anthropic") || lowerModel.contains("claude") {
            return try claudeBody(for: req)
        }
        if lowerModel.contains("llama") || lowerModel.contains("meta") {
            return try llamaBody(for: req)
        }
        return try claudeBody(for: req)
    }

    private func claudeBody(for req: LLMRequest) throws -> Data {
        let system = req.messages
            .filter { $0.role == .system }
            .map(\.content)
            .joined(separator: "\n\n")

        let messages = req.messages
            .filter { $0.role != .system }
            .map { ["role": $0.role.rawValue, "content": $0.content] }

        var body: [String: Any] = [
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": req.maxTokens,
            "temperature": req.temperature,
            "messages": messages
        ]
        if !system.isEmpty {
            body["system"] = system
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    private func llamaBody(for req: LLMRequest) throws -> Data {
        let prompt = req.messages.map { message in
            "\(message.role.rawValue): \(message.content)"
        }.joined(separator: "\n")

        return try JSONSerialization.data(withJSONObject: [
            "prompt": prompt,
            "max_gen_len": req.maxTokens,
            "temperature": req.temperature
        ])
    }
}

