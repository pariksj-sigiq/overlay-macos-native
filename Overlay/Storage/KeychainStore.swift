//
//  KeychainStore.swift
//  Overlay
//
//  String secret storage for provider credentials.
//

import Foundation
import Security
import CryptoKit

final class KeychainStore {
    enum KeychainStoreError: Error, LocalizedError {
        case invalidString
        case itemNotFound
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .invalidString:
                return "The keychain value could not be encoded or decoded as UTF-8."
            case .itemNotFound:
                return "No keychain item exists for that account."
            case .unexpectedStatus(let status):
                return "Keychain operation failed with status \(status)."
            }
        }
    }

    static let shared = KeychainStore()

    private let service: String

    init(service: String = "OverlayOpus") {
        self.service = service
    }

    func get(account: String) throws -> String {
        var query = baseQuery(account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status != errSecItemNotFound else {
            throw KeychainStoreError.itemNotFound
        }
        guard status == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
        guard let data = item as? Data,
              let string = String(data: data, encoding: .utf8) else {
            throw KeychainStoreError.invalidString
        }

        return string
    }

    func string(for account: String) async throws -> String? {
        do {
            return try get(account: account)
        } catch KeychainStoreError.itemNotFound {
            return nil
        }
    }

    func set(_ secret: String, account: String) throws {
        guard let data = secret.data(using: .utf8) else {
            throw KeychainStoreError.invalidString
        }

        let query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        guard updateStatus == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(addStatus)
        }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

final class LocalDataProtector {
    enum LocalDataProtectorError: Error {
        case randomGenerationFailed(OSStatus)
        case invalidKey
    }

    static let shared = LocalDataProtector()

    private static let keyAccount = "local-data-encryption-key-v1"
    private static let stringPrefix = "enc:v1:"
    private static let dataPrefix = Data(stringPrefix.utf8)

    private let keychain: KeychainStore
    private var cachedKey: SymmetricKey?

    init(keychain: KeychainStore = .shared) {
        self.keychain = keychain
    }

    func isEncryptedString(_ value: String) -> Bool {
        value.hasPrefix(Self.stringPrefix)
    }

    func isEncryptedData(_ value: Data) -> Bool {
        value.starts(with: Self.dataPrefix)
    }

    func hasStoredKey() -> Bool {
        guard let value = try? keychain.get(account: Self.keyAccount),
              let keyData = Data(base64Encoded: value) else {
            return false
        }
        return keyData.count == 32
    }

    func encryptString(_ value: String) throws -> String {
        guard !isEncryptedString(value) else { return value }
        let sealed = try AES.GCM.seal(Data(value.utf8), using: key())
        guard let combined = sealed.combined else { throw LocalDataProtectorError.invalidKey }
        return Self.stringPrefix + combined.base64EncodedString()
    }

    func decryptString(_ value: String) -> String {
        guard isEncryptedString(value) else { return value }
        let encoded = String(value.dropFirst(Self.stringPrefix.count))
        guard let combined = Data(base64Encoded: encoded),
              let sealed = try? AES.GCM.SealedBox(combined: combined),
              let opened = try? AES.GCM.open(sealed, using: key()),
              let text = String(data: opened, encoding: .utf8) else {
            return ""
        }
        return text
    }

    func encryptString(_ value: String?) throws -> String? {
        guard let value else { return nil }
        return try encryptString(value)
    }

    func decryptString(_ value: String?) -> String? {
        guard let value else { return nil }
        return decryptString(value)
    }

    func encryptData(_ value: Data) throws -> Data {
        guard !isEncryptedData(value) else { return value }
        let sealed = try AES.GCM.seal(value, using: key())
        guard let combined = sealed.combined else { throw LocalDataProtectorError.invalidKey }
        return Self.dataPrefix + Data(combined.base64EncodedString().utf8)
    }

    func decryptData(_ value: Data) -> Data {
        guard isEncryptedData(value) else { return value }
        let encoded = value.dropFirst(Self.dataPrefix.count)
        guard let encodedString = String(data: encoded, encoding: .utf8),
              let combined = Data(base64Encoded: encodedString),
              let sealed = try? AES.GCM.SealedBox(combined: combined),
              let opened = try? AES.GCM.open(sealed, using: key()) else {
            return Data()
        }
        return opened
    }

    func encryptData(_ value: Data?) throws -> Data? {
        guard let value else { return nil }
        return try encryptData(value)
    }

    func decryptData(_ value: Data?) -> Data? {
        guard let value else { return nil }
        return decryptData(value)
    }

    private func key() throws -> SymmetricKey {
        if let cachedKey {
            return cachedKey
        }

        if let existing = try? keychain.get(account: Self.keyAccount),
           let keyData = Data(base64Encoded: existing),
           keyData.count == 32 {
            let key = SymmetricKey(data: keyData)
            cachedKey = key
            return key
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw LocalDataProtectorError.randomGenerationFailed(status)
        }

        let keyData = Data(bytes)
        try keychain.set(keyData.base64EncodedString(), account: Self.keyAccount)
        let key = SymmetricKey(data: keyData)
        cachedKey = key
        return key
    }
}
