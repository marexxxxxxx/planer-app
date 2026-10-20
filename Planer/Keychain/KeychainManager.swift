//
//  KeychainManager.swift
//  Planer
//
//  Einziger Zugriff auf die Dienst-Geheimnisse (spec-ios §4).
//

import Foundation
import Security

/// Fehler der Keychain-Zugriffe.
enum KeychainError: Error, Equatable, LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            return "Keychain-Fehler (Status \(status))."
        case .invalidData:
            return "Keychain-Wert ist kein gültiger UTF-8-Text."
        }
    }
}

/// Liest und schreibt `kSecClassGenericPassword`-Items der vier Dienste.
///
/// Zweck: einzige Stelle, an der Dienst-Geheimnisse gespeichert werden; die
/// Accessibility ist für jedes Item `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
/// (spec-ios §4, AD-5).
/// Grenze: kein In-Memory-Cache und keine Synchronisation über Geräte hinweg.
struct KeychainManager: Sendable {
    /// Einzige Accessibility-Konstante der App (spec-ios §4).
    private static let accessibility = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

    /// Legt den Wert an oder überschreibt ihn.
    func set(_ value: String, for service: ServiceType, account: ServiceCredential) throws {
        let query = Self.baseQuery(service: service, account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: Self.accessibility
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        var addQuery = query
        for (key, value) in attributes {
            addQuery[key] = value
        }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    /// Liefert den Wert oder `nil`, wenn kein Item existiert.
    func value(for service: ServiceType, account: ServiceCredential) throws -> String? {
        var query = Self.baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        guard let data = item as? Data,
              let string = String(data: data, encoding: .utf8)
        else {
            throw KeychainError.invalidData
        }
        return string
    }

    /// Löscht einen einzelnen Wert; ein fehlendes Item ist kein Fehler.
    func remove(for service: ServiceType, account: ServiceCredential) throws {
        let status = SecItemDelete(Self.baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private static func baseQuery(
        service: ServiceType,
        account: ServiceCredential
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service.keychainService,
            kSecAttrAccount as String: account.rawValue
        ]
    }
}
