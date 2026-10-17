//
//  BoothSession.swift
//  photobooth
//
//  Durable record of one guest's accepted media + commercial state. Contains
//  no face landmarks/biometric tracking data — live face tracking stays
//  ephemeral (NormalizedFaceState/TrackedFaceState never touch disk). Only
//  what's needed for the guest's media and delivery/payment status is
//  persisted here.
//
//  Identifiers are UUIDs, never sequential/guessable — this type is also
//  never used as the public delivery secret itself; that's `claimToken`
//  (see ClaimTokenGenerator).
//

import Foundation

struct BoothSession: Codable, Identifiable, Equatable {
    enum Status: String, Codable {
        case active
        case delivered
        case expired
    }

    let id: UUID
    let eventID: UUID
    let createdAt: Date
    var updatedAt: Date
    var status: Status
    var selectedExperience: BoothExperience
    var mediaItems: [MediaItem]
    var claimToken: String
    var paymentState: PaymentState
    var entitlements: Set<Entitlement>
    var expirationDate: Date
}
