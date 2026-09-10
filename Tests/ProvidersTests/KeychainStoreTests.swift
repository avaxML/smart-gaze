import Foundation
import Providers
import Testing

private func uniqueTestService() -> String {
  let service = "com.avaxml.smartgaze.tests.\(UUID().uuidString)"
  print("KeychainStoreTests service: \(service)")
  return service
}

@Test func readingMissingAccountReturnsNil() throws {
  let store = KeychainStore(service: uniqueTestService())
  defer { try? store.delete(account: "missing") }

  #expect(try store.read(account: "missing") == nil)

  try store.delete(account: "missing")
  #expect(try store.read(account: "missing") == nil)
}

@Test func writingThenReadingReturnsTheSecret() throws {
  let store = KeychainStore(service: uniqueTestService())
  defer { try? store.delete(account: "api-key") }

  try store.write("test-secret-one", account: "api-key")
  #expect(try store.read(account: "api-key") == "test-secret-one")

  try store.delete(account: "api-key")
  #expect(try store.read(account: "api-key") == nil)
}

@Test func overwritingReplacesTheSecret() throws {
  let store = KeychainStore(service: uniqueTestService())
  defer { try? store.delete(account: "api-key") }

  try store.write("test-secret-one", account: "api-key")
  try store.write("test-secret-two", account: "api-key")
  #expect(try store.read(account: "api-key") == "test-secret-two")

  try store.delete(account: "api-key")
  #expect(try store.read(account: "api-key") == nil)
}

@Test func deletingRemovesTheSecret() throws {
  let store = KeychainStore(service: uniqueTestService())
  defer { try? store.delete(account: "api-key") }

  try store.write("test-secret-one", account: "api-key")
  try store.delete(account: "api-key")
  #expect(try store.read(account: "api-key") == nil)
}

@Test func deletingMissingAccountSucceeds() throws {
  let store = KeychainStore(service: uniqueTestService())
  defer { try? store.delete(account: "missing") }

  try store.delete(account: "missing")
  try store.delete(account: "missing")
  #expect(try store.read(account: "missing") == nil)
}

@Test func containsReportsPresenceWithoutReturningTheSecret() throws {
  let store = KeychainStore(service: uniqueTestService())
  defer { try? store.delete(account: "api-key") }

  #expect(try store.contains(account: "api-key") == false)

  try store.write("test-secret-one", account: "api-key")
  #expect(try store.contains(account: "api-key") == true)

  try store.delete(account: "api-key")
  #expect(try store.contains(account: "api-key") == false)
}

@Test func accountsAreIsolatedWithinAService() throws {
  let store = KeychainStore(service: uniqueTestService())
  defer {
    try? store.delete(account: "first")
    try? store.delete(account: "second")
  }

  try store.write("test-secret-one", account: "first")
  try store.write("test-secret-two", account: "second")
  #expect(try store.read(account: "first") == "test-secret-one")
  #expect(try store.read(account: "second") == "test-secret-two")

  try store.delete(account: "first")
  #expect(try store.read(account: "first") == nil)
  #expect(try store.read(account: "second") == "test-secret-two")

  try store.delete(account: "second")
  #expect(try store.read(account: "second") == nil)
}
