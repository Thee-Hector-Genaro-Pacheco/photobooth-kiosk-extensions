//
//  SupabaseDeliveryService.swift
//  photobooth
//
//  Real DigitalDeliveryService backed by Supabase: three small Edge
//  Functions (create-delivery-session, finalize-delivery-session,
//  resolve-claim — source in backend/supabase/functions/) plus direct
//  signed-URL uploads to private Storage. Plain URLSession, no Supabase SDK
//  dependency.
//
//  Two independent credentials travel with every privileged call:
//  - The Supabase publishable key (public) — Supabase's own platform gate,
//    just to reach the function at all.
//  - This installation's booth device credential (installationID +
//    Keychain-only token, see BoothDeviceIdentity.swift) — the app-level
//    authorization check inside the function body. Possession of the
//    publishable key alone is deliberately NOT enough to create upload
//    sessions; see backend/supabase/functions/_shared/boothAuth.ts.
//
//  `resolve-claim` is guest-facing and is never called from this service —
//  only the static claim page calls it, using the claim token itself as
//  the bearer capability.
//
//  `claimURL(for:)` never makes a network call: the public claim URL is a
//  pure function of the session's already-generated `claimToken` and the
//  configured claim host, so there's nothing to persist beyond the token
//  the app already has.
//

import Foundation

enum SupabaseDeliveryError: LocalizedError {
    case deviceNotProvisioned
    case network(String)
    case serverError(String)
    case invalidResponse
    case uploadFailed

    var errorDescription: String? {
        switch self {
        case .deviceNotProvisioned: "This booth hasn't been provisioned for delivery yet."
        case .network(let message): "A network error occurred while uploading your media: \(message)"
        case .serverError(let message): "The delivery server reported an error: \(message)"
        case .invalidResponse: "The delivery server returned an unexpected response."
        case .uploadFailed: "The media upload failed."
        }
    }
}

final class SupabaseDeliveryService: DigitalDeliveryService {
    private let configuration: SupabaseDeliveryConfiguration
    private let sessionRepository: SessionRepository
    private let deviceIdentityStore: BoothDeviceIdentityStore
    private let urlSession: URLSession

    init(
        configuration: SupabaseDeliveryConfiguration,
        sessionRepository: SessionRepository = SessionRepository(),
        deviceIdentityStore: BoothDeviceIdentityStore = BoothDeviceIdentityStore(),
        urlSession: URLSession = .shared
    ) {
        self.configuration = configuration
        self.sessionRepository = sessionRepository
        self.deviceIdentityStore = deviceIdentityStore
        self.urlSession = urlSession
    }

    func prepareDelivery(for session: BoothSession) async throws {
        let manifest = session.mediaItems.map {
            CreateDeliverySessionRequest.MediaManifestEntry(mediaID: $0.id.uuidString, kind: $0.kind.rawValue, mimeType: $0.mimeType)
        }
        let created: CreateDeliverySessionResponse = try await callPrivilegedFunction(
            "create-delivery-session",
            body: CreateDeliverySessionRequest(
                eventID: session.eventID.uuidString,
                localSessionID: session.id.uuidString,
                claimToken: session.claimToken,
                expiresAt: ISO8601DateFormatter().string(from: session.expirationDate),
                media: manifest
            )
        )

        for item in session.mediaItems {
            guard let target = created.uploads.first(where: { $0.mediaID == item.id.uuidString }) else {
                throw SupabaseDeliveryError.invalidResponse
            }
            let fileURL = sessionRepository.resolvedURL(for: item, in: session)
            try await upload(fileURL: fileURL, to: target.uploadURL, mimeType: item.mimeType)
        }

        let _: FinalizeDeliverySessionResponse = try await callPrivilegedFunction(
            "finalize-delivery-session",
            body: FinalizeDeliverySessionRequest(deliverySessionID: created.deliverySessionID)
        )
    }

    func claimURL(for session: BoothSession) throws -> URL {
        configuration.publicClaimBaseURL.appendingPathComponent("s").appendingPathComponent(session.claimToken)
    }

    /// POSTs to a privileged Edge Function with both the publishable key
    /// (Supabase's platform gate) and this installation's booth device
    /// headers (the app's own authorization check). Fails fast with
    /// `.deviceNotProvisioned` before making any network call if this
    /// installation has no Keychain credential yet.
    private func callPrivilegedFunction<Body: Encodable, Response: Decodable>(_ name: String, body: Body) async throws -> Response {
        guard let credential = deviceIdentityStore.currentCredential() else {
            throw SupabaseDeliveryError.deviceNotProvisioned
        }

        let endpoint = configuration.projectURL.appendingPathComponent("functions/v1/\(name)")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.publishableKey)", forHTTPHeaderField: "Authorization")
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue(credential.installationID.uuidString, forHTTPHeaderField: "X-Booth-Installation-ID")
        request.setValue(Self.hexEncode(credential.rawToken), forHTTPHeaderField: "X-Booth-Token")
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw SupabaseDeliveryError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw SupabaseDeliveryError.invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403 {
            // The server rejected our booth device credential specifically
            // (missing/unregistered/disabled) — distinct from a generic
            // server error so the guest/admin UI can say so plainly.
            throw SupabaseDeliveryError.deviceNotProvisioned
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SupabaseDeliveryError.serverError(String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)")
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw SupabaseDeliveryError.invalidResponse
        }
    }

    /// Streams the file directly from disk (never loads a whole Loop video
    /// into memory) via a plain PUT to the signed upload URL the Edge
    /// Function returned. Simple upload only this pass — deliberately not
    /// resumable yet (see file header / backend README).
    private func upload(fileURL: URL, to uploadURL: URL, mimeType: String) async throws {
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")

        let response: URLResponse
        do {
            (_, response) = try await urlSession.upload(for: request, fromFile: fileURL)
        } catch {
            throw SupabaseDeliveryError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SupabaseDeliveryError.uploadFailed
        }
    }

    private static func hexEncode(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Wire types (must match backend/supabase/functions exactly)

private struct CreateDeliverySessionRequest: Encodable {
    struct MediaManifestEntry: Encodable {
        let mediaID: String
        let kind: String
        let mimeType: String
    }
    let eventID: String
    let localSessionID: String
    let claimToken: String
    let expiresAt: String
    let media: [MediaManifestEntry]
}

private struct CreateDeliverySessionResponse: Decodable {
    struct UploadTarget: Decodable {
        let mediaID: String
        let uploadURL: URL
    }
    let deliverySessionID: String
    let uploads: [UploadTarget]
}

private struct FinalizeDeliverySessionRequest: Encodable {
    let deliverySessionID: String
}

private struct FinalizeDeliverySessionResponse: Decodable {
    let status: String
}
