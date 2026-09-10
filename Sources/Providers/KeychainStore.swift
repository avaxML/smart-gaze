import Foundation
import Security

public protocol SecretStore: Sendable {
  func read(account: String) throws -> String?
  func write(_ secret: String, account: String) throws
  func delete(account: String) throws
}

public enum KeychainError: Error, Equatable {
  case unexpectedStatus(OSStatus)
  case unreadableData
}

public struct KeychainStore: SecretStore, Sendable {
  private let service: String

  public init(service: String = "com.avaxml.smartgaze") {
    self.service = service
  }

  public func read(account: String) throws -> String? {
    var query = baseQuery(account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    guard let data = item as? Data, let secret = String(data: data, encoding: .utf8) else {
      throw KeychainError.unreadableData
    }
    return secret
  }

  public func write(_ secret: String, account: String) throws {
    let data = Data(secret.utf8)
    if try read(account: account) != nil {
      let status = SecItemUpdate(
        baseQuery(account: account) as CFDictionary,
        [kSecValueData as String: data] as CFDictionary
      )
      guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
      return
    }
    var query = baseQuery(account: account)
    query[kSecValueData as String] = data
    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
  }

  public func delete(account: String) throws {
    let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError.unexpectedStatus(status)
    }
  }

  private func baseQuery(account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }
}
