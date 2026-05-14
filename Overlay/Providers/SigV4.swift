//
//  SigV4.swift
//  OverlayOpus
//

import CryptoKit
import Foundation

struct SigV4Credentials: Equatable {
    let accessKeyID: String
    let secretAccessKey: String
    let sessionToken: String?
}

struct SigV4 {
    let service: String
    let region: String
    let credentials: SigV4Credentials

    func sign(_ request: URLRequest, body: Data, date: Date = Date()) throws -> URLRequest {
        guard let url = request.url, let host = url.host else {
            throw LLMProviderError.invalidConfiguration("SigV4 request is missing URL host")
        }

        var signed = request
        let timestamp = Self.timestampFormatter.string(from: date)
        let day = Self.dayFormatter.string(from: date)
        let payloadHash = Self.sha256Hex(body)

        signed.setValue(host, forHTTPHeaderField: "Host")
        signed.setValue(timestamp, forHTTPHeaderField: "X-Amz-Date")
        signed.setValue(payloadHash, forHTTPHeaderField: "X-Amz-Content-Sha256")
        if let sessionToken = credentials.sessionToken, !sessionToken.isEmpty {
            signed.setValue(sessionToken, forHTTPHeaderField: "X-Amz-Security-Token")
        }

        let canonical = canonicalRequest(for: signed, payloadHash: payloadHash)
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            timestamp,
            scope,
            Self.sha256Hex(Data(canonical.utf8))
        ].joined(separator: "\n")

        let signingKey = Self.signingKey(secret: credentials.secretAccessKey,
                                         day: day,
                                         region: region,
                                         service: service)
        let signature = Self.hmacHex(key: signingKey, message: stringToSign)
        let signedHeaders = canonicalHeaders(for: signed).signedHeaders
        let authorization = "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        signed.setValue(authorization, forHTTPHeaderField: "Authorization")
        return signed
    }

    private func canonicalRequest(for request: URLRequest, payloadHash: String) -> String {
        let method = request.httpMethod ?? "GET"
        let url = request.url
        let path = url?.path.isEmpty == false ? url?.path ?? "/" : "/"
        let query = canonicalQuery(url?.query ?? "")
        let headers = canonicalHeaders(for: request)

        return [
            method,
            path,
            query,
            headers.canonicalHeaders,
            headers.signedHeaders,
            payloadHash
        ].joined(separator: "\n")
    }

    private func canonicalQuery(_ query: String) -> String {
        guard !query.isEmpty else { return "" }
        return query
            .split(separator: "&")
            .map(String.init)
            .sorted()
            .joined(separator: "&")
    }

    private func canonicalHeaders(for request: URLRequest) -> (canonicalHeaders: String, signedHeaders: String) {
        let headers = request.allHTTPHeaderFields ?? [:]
        let normalized = headers.map { key, value in
            (key.lowercased(), value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        .sorted { $0.0 < $1.0 }

        let canonical = normalized.map { "\($0.0):\($0.1)" }.joined(separator: "\n") + "\n"
        let signed = normalized.map(\.0).joined(separator: ";")
        return (canonical, signed)
    }

    private static func signingKey(secret: String, day: String, region: String, service: String) -> SymmetricKey {
        let kDate = hmacData(key: SymmetricKey(data: Data("AWS4\(secret)".utf8)), message: day)
        let kRegion = hmacData(key: SymmetricKey(data: kDate), message: region)
        let kService = hmacData(key: SymmetricKey(data: kRegion), message: service)
        let kSigning = hmacData(key: SymmetricKey(data: kService), message: "aws4_request")
        return SymmetricKey(data: kSigning)
    }

    private static func hmacData(key: SymmetricKey, message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key))
    }

    private static func hmacHex(key: SymmetricKey, message: String) -> String {
        hmacData(key: key, message: message).map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()
}

