//
//  BoothDeviceIdentity.swift
//  photobooth
//
//  This installation's credential for calling privileged delivery
//  operations (create-delivery-session, finalize-delivery-session).
//  Possession of the Supabase publishable key is public and must never be
//  sufficient on its own to trigger those — this is the second factor the
//  backend actually authorizes against (see backend/supabase/functions/
//  _shared/boothAuth.ts).
//
//  Token lifecycle (exact semantics — keep this accurate if it changes):
//  - The raw token is stored persistently ONLY in the iOS Keychain, scoped
//    `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — it cannot migrate
//    to another physical device via backup/restore, iCloud, or Migration
//    Assistant. It stays wherever it was generated.
//  - It is loaded into memory only transiently, at the moment a privileged
//    request is built (see SupabaseDeliveryService.callPrivilegedFunction),
//    and discarded immediately after.
//  - It is transmitted over HTTPS as the `X-Booth-Token` header value —
//    never over plain HTTP, never as a query parameter.
//  - It is never logged, never displayed in any UI (including this app's
//    own admin screen), never written to a plist/UserDefaults/file, and
//    never committed to Git.
//  - Hector never manually copies the raw token anywhere — provisioning
//    only ever surfaces `installationID` and `tokenHash`
//    (SHA-256 of the token), both safe to paste into the Supabase
//    dashboard. The server (`booth_devices.token_hash`) stores only that
//    hash — never the raw token.
//
//  `installationID` is not secret and lives in UserDefaults.
//

import CryptoKit
import Foundation
import Security

/// Public-safe descriptor: everything here is fine to display to an admin
/// or copy into the Supabase dashboard. The raw token is never part of
/// this type.
struct BoothDeviceIdentity: Equatable {
    let installationID: UUID
    let tokenHash: String
}

/// Local provisioning state. `.registered` is never inferred merely from a
/// Keychain identity existing — it's only reached after
/// `markCurrentIdentityAsRegistered()` is called following a real,
/// successful round-trip confirmation against the backend (see
/// SupabaseDeliveryService.verifyDeviceRegistration and
/// AdminEventEditorView). There is no fake/local-only confirmation path.
enum BoothDeviceProvisioningStatus: Equatable {
    case notGenerated
    case identityGenerated(BoothDeviceIdentity)
    case registered(BoothDeviceIdentity)

    var identity: BoothDeviceIdentity? {
        switch self {
        case .notGenerated: nil
        case .identityGenerated(let identity), .registered(let identity): identity
        }
    }
}

enum BoothDeviceIdentityError: LocalizedError {
    case randomGenerationFailed
    case keychainWriteFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .randomGenerationFailed: "Could not generate a secure device token."
        case .keychainWriteFailed(let status): "Could not save the device token to the Keychain (status \(status))."
        }
    }
}

final class BoothDeviceIdentityStore {
    private static let installationIDDefaultsKey = "org.firmecoding.photobooth.installationID"
    private static let registeredInstallationIDDefaultsKey = "org.firmecoding.photobooth.registeredInstallationID"
    private static let keychainService = "org.firmecoding.photobooth.boothDeviceToken"
    private static let keychainAccount = "boothDeviceToken"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The current installation's public-safe descriptor, or `nil` if this
    /// installation hasn't been provisioned yet. Never exposes the raw token.
    func currentIdentity() -> BoothDeviceIdentity? {
        guard let installationID = storedInstallationID() else { return nil }
        guard let token = readTokenFromKeychain() else {
            // The Keychain token is gone — most commonly because this
            // UserDefaults value migrated to a new physical device (e.g.
            // via backup/restore) while the ThisDeviceOnly-protected
            // Keychain item correctly did not. Clear the now-stale
            // installation ID rather than ever treating it as though its
            // credential still exists; a future provisioning action will
            // generate a fully fresh, coherent pair.
            defaults.removeObject(forKey: Self.installationIDDefaultsKey)
            return nil
        }
        return BoothDeviceIdentity(installationID: installationID, tokenHash: Self.sha256Hex(token))
    }

    /// The tri-state status the admin UI should actually show. Distinct
    /// from `currentIdentity() != nil` — a locally-generated identity is
    /// `.identityGenerated` (registration required) until a real backend
    /// check confirms it, never presented as `.registered` prematurely.
    func provisioningStatus() -> BoothDeviceProvisioningStatus {
        guard let identity = currentIdentity() else { return .notGenerated }
        if defaults.string(forKey: Self.registeredInstallationIDDefaultsKey) == identity.installationID.uuidString {
            return .registered(identity)
        }
        return .identityGenerated(identity)
    }

    /// Generates a fresh installation ID + 32-byte random token and stores
    /// the token in the Keychain, replacing any previous one. Destructive:
    /// any backend `booth_devices` row for the old identity becomes
    /// orphaned, and any prior registration confirmation is invalidated.
    /// Callers (the admin UI) must confirm with the admin before calling
    /// this when already provisioned.
    @discardableResult
    func generateNewIdentity() throws -> BoothDeviceIdentity {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw BoothDeviceIdentityError.randomGenerationFailed
        }
        let token = Data(bytes)
        try writeTokenToKeychain(token)

        let installationID = UUID()
        defaults.set(installationID.uuidString, forKey: Self.installationIDDefaultsKey)
        defaults.removeObject(forKey: Self.registeredInstallationIDDefaultsKey)

        return BoothDeviceIdentity(installationID: installationID, tokenHash: Self.sha256Hex(token))
    }

    /// Records that a real backend round-trip (`verify-device`) confirmed
    /// this exact installation is registered and enabled. Must only be
    /// called after an actual successful verification response — never
    /// speculatively, and never as a substitute for one.
    func markCurrentIdentityAsRegistered() {
        guard let identity = currentIdentity() else { return }
        defaults.set(identity.installationID.uuidString, forKey: Self.registeredInstallationIDDefaultsKey)
    }

    /// Raw credential for outgoing requests only. Loaded into memory here
    /// and nowhere else persistent — callers must hex-encode this directly
    /// into a request header and let it fall out of scope immediately
    /// after. Never logged, never shown in any UI.
    func currentCredential() -> (installationID: UUID, rawToken: Data)? {
        guard let installationID = storedInstallationID(), let token = readTokenFromKeychain() else { return nil }
        return (installationID, token)
    }

    private func storedInstallationID() -> UUID? {
        defaults.string(forKey: Self.installationIDDefaultsKey).flatMap(UUID.init(uuidString:))
    }

    private func writeTokenToKeychain(_ token: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
        ]
        // Replace any existing value outright — a new identity fully
        // supersedes the old one.
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = token
        // ThisDeviceOnly: this credential is tied to this specific
        // physical device's Secure Enclave-backed keybag and will never
        // migrate via iCloud Keychain, encrypted backup restore, or
        // Migration Assistant — restoring to a new device leaves this
        // item behind rather than cloning a booth's identity onto a
        // second iPad.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw BoothDeviceIdentityError.keychainWriteFailed(status) }
    }

    private func readTokenFromKeychain() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return data
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
