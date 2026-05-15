//
//  BedrockProvider.swift
//  OverlayOpus
//

import Foundation

struct BedrockProviderConfig: Codable, Equatable {
    var region: String
    var defaultModelID: String?
    var accessKeyIDSecretName: String
    var secretAccessKeySecretName: String
    var sessionTokenSecretName: String?

    init(region: String,
         defaultModelID: String? = nil,
         accessKeyIDSecretName: String = "bedrock.accessKeyID",
         secretAccessKeySecretName: String = "bedrock.secretAccessKey",
         sessionTokenSecretName: String? = "bedrock.sessionToken") {
        self.region = region
        self.defaultModelID = defaultModelID
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

                    var parser = BedrockEventStreamParser()
                    for try await byte in bytes {
                        for message in try parser.feed(Data([byte])) {
                            for token in try Self.extractTokens(from: message) where !token.isEmpty {
                                continuation.yield(.token(token))
                            }
                        }
                    }

                    for message in try parser.finish() {
                        for token in try Self.extractTokens(from: message) where !token.isEmpty {
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
        throw LLMProviderError.unsupported("Bedrock runtime streaming is supported, but model listing is not available from this provider. Enter a model ID in Settings.")
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
        request.setValue("application/json", forHTTPHeaderField: "X-Amzn-Bedrock-Accept")

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

    private static func extractTokens(from message: BedrockEventStreamMessage) throws -> [String] {
        if message.headers[":message-type"] == "exception" {
            let detail = String(data: message.payload, encoding: .utf8) ?? "Bedrock returned a streaming exception"
            let type = message.headers[":exception-type"] ?? message.headers[":error-code"] ?? "exception"
            throw LLMProviderError.invalidResponse("Bedrock \(type): \(detail)")
        }

        guard message.payload.isEmpty == false else { return [] }
        let payload = try unwrapPayload(message.payload)
        let json = try JSONSerialization.jsonObject(with: payload)
        guard let root = json as? [String: Any] else { return [] }

        var tokens: [String] = []

        if let type = root["type"] as? String {
            switch type {
            case "content_block_delta":
                if let delta = root["delta"] as? [String: Any],
                   let text = delta["text"] as? String {
                    tokens.append(text)
                }
            case "content_block_start":
                if let block = root["content_block"] as? [String: Any],
                   let text = block["text"] as? String {
                    tokens.append(text)
                }
            default:
                break
            }
        }

        if tokens.isEmpty,
           let delta = root["delta"] as? [String: Any],
           let text = delta["text"] as? String {
            tokens.append(text)
        }

        if let completion = root["completion"] as? String {
            tokens.append(completion)
        }
        if let generation = root["generation"] as? String {
            tokens.append(generation)
        }
        if let outputText = root["outputText"] as? String {
            tokens.append(outputText)
        }
        if let outputs = root["outputs"] as? [[String: Any]] {
            tokens.append(contentsOf: outputs.compactMap { output in
                output["text"] as? String ?? output["generation"] as? String
            })
        }

        return tokens
    }

    private static func unwrapPayload(_ payload: Data) throws -> Data {
        guard let json = try? JSONSerialization.jsonObject(with: payload),
              let root = json as? [String: Any] else {
            return payload
        }

        if let bytes = root["bytes"] as? String,
           let decoded = Data(base64Encoded: bytes) {
            return decoded
        }

        if let chunk = root["chunk"] as? [String: Any],
           let bytes = chunk["bytes"] as? String,
           let decoded = Data(base64Encoded: bytes) {
            return decoded
        }

        return payload
    }
}

private struct BedrockEventStreamMessage {
    let headers: [String: String]
    let payload: Data
}

private struct BedrockEventStreamParser {
    private var buffer = Data()

    mutating func feed(_ data: Data) throws -> [BedrockEventStreamMessage] {
        buffer.append(data)

        var messages: [BedrockEventStreamMessage] = []
        while buffer.count >= 12 {
            let totalLength = Int(Self.uint32(in: buffer, at: 0))
            guard totalLength >= 16 else {
                throw LLMProviderError.invalidResponse("Bedrock event stream message length was invalid")
            }
            guard buffer.count >= totalLength else { break }

            let messageData = Data(buffer.prefix(totalLength))
            buffer.removeFirst(totalLength)
            messages.append(try Self.parse(messageData))
        }
        return messages
    }

    mutating func finish() throws -> [BedrockEventStreamMessage] {
        guard !buffer.isEmpty else { return [] }
        defer { buffer.removeAll() }
        throw LLMProviderError.invalidResponse("Bedrock event stream ended with an incomplete message")
    }

    private static func parse(_ message: Data) throws -> BedrockEventStreamMessage {
        let totalLength = Int(uint32(in: message, at: 0))
        let headersLength = Int(uint32(in: message, at: 4))
        let headersStart = 12
        let headersEnd = headersStart + headersLength
        let payloadEnd = totalLength - 4

        guard totalLength == message.count,
              headersEnd <= payloadEnd,
              payloadEnd <= message.count else {
            throw LLMProviderError.invalidResponse("Bedrock event stream frame was malformed")
        }

        var headers: [String: String] = [:]
        var index = headersStart
        while index < headersEnd {
            let nameLength = Int(message[index])
            index += 1
            guard index + nameLength + 1 <= headersEnd else {
                throw LLMProviderError.invalidResponse("Bedrock event stream header was truncated")
            }

            let nameData = message[index..<index + nameLength]
            index += nameLength
            guard let name = String(data: nameData, encoding: .utf8) else {
                throw LLMProviderError.invalidResponse("Bedrock event stream header name was not UTF-8")
            }

            let valueType = message[index]
            index += 1
            let value = try readHeaderValue(type: valueType, from: message, index: &index, limit: headersEnd)
            headers[name] = value
        }

        return BedrockEventStreamMessage(headers: headers,
                                         payload: Data(message[headersEnd..<payloadEnd]))
    }

    private static func readHeaderValue(type: UInt8, from data: Data, index: inout Int, limit: Int) throws -> String {
        switch type {
        case 0:
            return "true"
        case 1:
            return "false"
        case 2:
            guard index + 1 <= limit else { throw truncatedHeaderValue() }
            defer { index += 1 }
            return String(Int8(bitPattern: data[index]))
        case 3:
            guard index + 2 <= limit else { throw truncatedHeaderValue() }
            let value = Int16(bitPattern: uint16(in: data, at: index))
            index += 2
            return String(value)
        case 4:
            guard index + 4 <= limit else { throw truncatedHeaderValue() }
            let value = Int32(bitPattern: uint32(in: data, at: index))
            index += 4
            return String(value)
        case 5, 8:
            guard index + 8 <= limit else { throw truncatedHeaderValue() }
            let value = int64(in: data, at: index)
            index += 8
            return String(value)
        case 6, 7:
            guard index + 2 <= limit else { throw truncatedHeaderValue() }
            let length = Int(uint16(in: data, at: index))
            index += 2
            guard index + length <= limit else { throw truncatedHeaderValue() }
            let valueData = data[index..<index + length]
            index += length
            if type == 7 {
                guard let value = String(data: valueData, encoding: .utf8) else {
                    throw LLMProviderError.invalidResponse("Bedrock event stream string header was not UTF-8")
                }
                return value
            }
            return valueData.base64EncodedString()
        case 9:
            guard index + 16 <= limit else { throw truncatedHeaderValue() }
            let valueData = data[index..<index + 16]
            index += 16
            return valueData.map { String(format: "%02x", $0) }.joined()
        default:
            throw LLMProviderError.invalidResponse("Bedrock event stream used unsupported header type \(type)")
        }
    }

    private static func truncatedHeaderValue() -> LLMProviderError {
        LLMProviderError.invalidResponse("Bedrock event stream header value was truncated")
    }

    private static func uint16(in data: Data, at index: Int) -> UInt16 {
        (UInt16(data[index]) << 8) | UInt16(data[index + 1])
    }

    private static func uint32(in data: Data, at index: Int) -> UInt32 {
        (UInt32(data[index]) << 24)
            | (UInt32(data[index + 1]) << 16)
            | (UInt32(data[index + 2]) << 8)
            | UInt32(data[index + 3])
    }

    private static func int64(in data: Data, at index: Int) -> Int64 {
        var value: UInt64 = 0
        for offset in 0..<8 {
            value = (value << 8) | UInt64(data[index + offset])
        }
        return Int64(bitPattern: value)
    }
}
