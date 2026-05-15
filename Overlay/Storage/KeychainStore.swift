//
//  KeychainStore.swift
//  Overlay
//
//  String secret storage for provider credentials.
//

import Foundation
import Security

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

    func delete(accounts: [String]) throws {
        for account in Set(accounts) {
            try delete(account: account)
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
