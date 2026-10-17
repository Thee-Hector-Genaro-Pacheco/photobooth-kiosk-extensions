//
//  EventConfiguration.swift
//  photobooth
//
//  Event-level commercial configuration. A future settings/admin UI would
//  read and write values of this type — nothing here assumes it can only be
//  constructed at compile time (see DevelopmentEventConfigurations for the
//  development-only construction mechanism this phase actually uses).
//

import Foundation

enum EventOperatingMode: String, Codable {
    /// A client/organization is paying for the event; guests aren't charged.
    case sponsored
    /// No paid event contract; guests pay per product.
    case selfServe
    /// Some products are free, others cost money.
    case hybrid
    /// Guest media is free; optional branding/social CTA may be shown.
    case promotional
}

/// Optional, dismissible prompt shown alongside delivery. Never a condition
/// of receiving media — see BoothFlow/DeliveryView for enforcement.
struct SocialCTA: Codable, Equatable {
    enum Platform: String, Codable {
        case instagram, tiktok, facebook, x, other
    }

    var platform: Platform
    var displayName: String
    var profileURL: URL
    var message: String
}

/// How long a guest's media should be considered valid for delivery before
/// it's eligible for cleanup. Storing this is the only retention behavior
/// implemented this phase — see MediaRetentionCleanupService for why no
/// automatic deletion runs yet.
enum MediaRetentionPolicy: Codable, Equatable {
    case hours(Int)
    case days(Int)

    var duration: TimeInterval {
        switch self {
        case .hours(let count): TimeInterval(count) * 3600
        case .days(let count): TimeInterval(count) * 86400
        }
    }
}

struct EventConfiguration: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var operatingMode: EventOperatingMode
    var availableExperiences: [BoothExperience]
    var productPricing: [BoothProduct: Money]
    var printingEnabled: Bool
    var digitalDeliveryEnabled: Bool
    var socialCTA: SocialCTA?
    var mediaRetentionPolicy: MediaRetentionPolicy

    func price(for product: BoothProduct) -> Money {
        productPricing[product] ?? .free()
    }
}
