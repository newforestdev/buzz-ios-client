import CryptoKit
import Foundation
import NostrCore
import Security

/// Retains the handle, epoch and App Attest key ID needed to revoke a stranded
/// installation. No APNs token or private key is stored here.
struct PushInstallationRecord: Codable, Equatable, Sendable {
    let gatewayOrigin: String
    let tokenHash: String
    let installation: PushInstallation
}

protocol PushInstallationStore: Sendable {
    func load() throws -> [PushInstallationRecord]
    func save(_ record: PushInstallationRecord) throws
    func remove(_ record: PushInstallationRecord) throws
}

struct PushEnrollmentRecovery: Sendable {
    let store: any PushInstallationStore
    var now: @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }

    func remember(_ installation: PushInstallation, gateway: PushGatewayClient, tokenHash: String) throws {
        let archived = try store.load().first {
            $0.gatewayOrigin == gateway.gatewayOrigin && $0.installation.handle == installation.handle
        }
        if let archived,
           archived.installation.endpointEpoch > installation.endpointEpoch
            || (archived.installation.endpointEpoch == installation.endpointEpoch
                && archived.installation.expiresAt > installation.expiresAt) {
            return
        }
        try store.save(PushInstallationRecord(
            gatewayOrigin: gateway.gatewayOrigin, tokenHash: tokenHash, installation: installation
        ))
    }

    func restoredRecord(for installation: PushInstallation, gateway: PushGatewayClient) throws -> PushInstallationRecord? {
        try store.load().first {
            $0.gatewayOrigin == gateway.gatewayOrigin && $0.installation.handle == installation.handle
                && $0.installation.endpointEpoch >= installation.endpointEpoch
        }
    }

    func enroll(
        gateway: PushGatewayClient,
        token: Data,
        expiresAt: Int64,
        attester: any PushAttesting
    ) async throws -> PushInstallation {
        let tokenHash = Data(SHA256.hash(data: token)).hexString
        do {
            return try await enrollAndRemember(gateway, token: token, tokenHash: tokenHash,
                                               expiresAt: expiresAt, attester: attester)
        } catch PushGatewayError.installationConflict {
            let records = try store.load().filter {
                $0.gatewayOrigin == gateway.gatewayOrigin && $0.tokenHash == tokenHash
            }
            guard !records.isEmpty else { throw PushGatewayError.missingInstallationCredentials }
            for record in records {
                try Task.checkCancellation()
                do {
                    try await gateway.revoke(installation: record.installation, attester: attester)
                } catch PushGatewayError.httpStatus(404) {
                    // A 404 can mean a consumed challenge, not a missing installation.
                    // Only expiry makes it safe to discard these credentials.
                    guard record.installation.expiresAt < now() else {
                        throw PushGatewayError.httpStatus(404)
                    }
                }
                try store.remove(record)
            }
            // The conflicted request cannot be reused once its old installation is
            // revoked. Get a new key/challenge and retry exactly once.
            gateway.completeEnrollmentJournal()
            try Task.checkCancellation()
            return try await enrollAndRemember(gateway, token: token, tokenHash: tokenHash,
                                               expiresAt: expiresAt, attester: attester)
        }
    }

    private func enrollAndRemember(
        _ gateway: PushGatewayClient,
        token: Data,
        tokenHash: String,
        expiresAt: Int64,
        attester: any PushAttesting
    ) async throws -> PushInstallation {
        let installation = try await gateway.enroll(
            token: token, profile: PushGatewayClient.appProfile, expiresAt: expiresAt, attester: attester
        )
        // Save before returning, including when cancellation arrived during HTTP.
        // The enrollment journal remains available if this write fails.
        try remember(installation, gateway: gateway, tokenHash: tokenHash)
        return installation
    }
}

final class KeychainPushInstallationStore: PushInstallationStore, @unchecked Sendable {
    static let shared = KeychainPushInstallationStore()
    private let lock = NSLock()
    private let service = "net.steelbeach.hive.push.installations"

    func load() throws -> [PushInstallationRecord] {
        try lock.withLock { try read() }
    }

    func save(_ record: PushInstallationRecord) throws {
        try lock.withLock {
            var records = try read()
            records.removeAll {
                $0.gatewayOrigin == record.gatewayOrigin && $0.installation.handle == record.installation.handle
            }
            records.append(record)
            try write(records)
        }
    }

    func remove(_ record: PushInstallationRecord) throws {
        try lock.withLock {
            var records = try read()
            // A slow recovery must not delete credentials updated in the meantime.
            records.removeAll { $0 == record }
            try write(records)
        }
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: "records-v1",
         kSecUseDataProtectionKeychain as String: true]
    }

    private func read() throws -> [PushInstallationRecord] {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = value as? Data else { throw PushGatewayError.journalFailure }
        return try JSONDecoder().decode([PushInstallationRecord].self, from: data)
    }

    private func write(_ records: [PushInstallationRecord]) throws {
        let data = try JSONEncoder().encode(records)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var request = query
            request[kSecValueData as String] = data
            request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(request as CFDictionary, nil) == errSecSuccess else { throw PushGatewayError.journalFailure }
        } else if status != errSecSuccess {
            throw PushGatewayError.journalFailure
        }
    }
}
