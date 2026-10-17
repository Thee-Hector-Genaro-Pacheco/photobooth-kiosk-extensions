//
//  DigitalDeliveryService.swift
//  photobooth
//
//  Boundary between the booth and whatever eventually hosts guest media for
//  remote claim (object storage + backend API + signed download links, or
//  something else — genuinely undecided). No production backend exists yet,
//  so the only implementation here is the honest "not configured" one. The
//  rest of the app must be able to proceed (showing a clear unavailable
//  state) without knowing which backend will ultimately provide this.
//

import Foundation

enum DeliveryError: LocalizedError {
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Remote delivery not configured"
        }
    }
}

protocol DigitalDeliveryService {
    /// Makes `session`'s media available for remote claim (e.g. uploads it).
    /// Throws `DeliveryError.notConfigured` when no backend exists.
    func prepareDelivery(for session: BoothSession) async throws
    /// The URL a guest would visit to claim their media. Only meaningful
    /// after `prepareDelivery(for:)` has succeeded.
    func claimURL(for session: BoothSession) throws -> URL
}

/// The safe default: no backend is configured, so this never claims to have
/// uploaded anything or fabricates a URL that leads nowhere.
struct UnconfiguredDeliveryService: DigitalDeliveryService {
    func prepareDelivery(for session: BoothSession) async throws {
        throw DeliveryError.notConfigured
    }

    func claimURL(for session: BoothSession) throws -> URL {
        throw DeliveryError.notConfigured
    }
}
