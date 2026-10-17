//
//  EventPolicy.swift
//  photobooth
//
//  The one authoritative place that decides what an EventConfiguration
//  actually allows to happen to a guest's wallet. `productPricing` is raw
//  configured data, editable by an admin — it is NEVER trusted directly for
//  charging decisions. Every call site that needs to know "can this guest be
//  charged for X" or "is this configuration even valid" goes through here,
//  not through scattered `if operatingMode == .sponsored` checks in views.
//

import Foundation

enum EventConfigurationValidationError: LocalizedError, Equatable {
    case guestPaymentUnderFreeMode(product: BoothProduct)
    case noDeliveryMechanismAvailable
    case invalidSocialURL
    case invalidColor(field: String, value: String)
    case invalidRetentionDuration

    var errorDescription: String? {
        switch self {
        case .guestPaymentUnderFreeMode(let product):
            "\(product.rawValue) has a non-zero guest price, but sponsored/promotional events must never charge guests."
        case .noDeliveryMechanismAvailable:
            "Digital delivery and printing are both disabled with experiences offered — guests would have no way to receive their media."
        case .invalidSocialURL:
            "The social profile URL is missing a scheme or host."
        case .invalidColor(let field, let value):
            "\(field) (\"\(value)\") is not a valid #RRGGBB color."
        case .invalidRetentionDuration:
            "Media retention duration must be greater than zero."
        }
    }
}

enum EventPolicy {
    /// Operating modes where a guest must never be charged, regardless of
    /// what `productPricing` contains. This is the hard domain invariant:
    /// sponsored means the host already paid, promotional means free by
    /// design.
    private static func guestsAreNeverCharged(under mode: EventOperatingMode) -> Bool {
        switch mode {
        case .sponsored, .promotional: true
        case .selfServe, .hybrid: false
        }
    }

    /// Whether a guest could ever be routed to checkout for `product`.
    static func guestMayBeCharged(for product: BoothProduct, in configuration: EventConfiguration) -> Bool {
        guard !guestsAreNeverCharged(under: configuration.operatingMode) else { return false }
        return !effectivePrice(for: product, in: configuration).isFree
    }

    /// The price that actually applies once operating-mode policy overrides
    /// raw `productPricing` — a mis-entered non-zero price in a sponsored
    /// event is harmless because nothing ever reads `productPricing`
    /// directly for a charge decision.
    static func effectivePrice(for product: BoothProduct, in configuration: EventConfiguration) -> Money {
        guard !guestsAreNeverCharged(under: configuration.operatingMode) else {
            return .free(currencyCode: configuration.productPricing[product]?.currencyCode ?? "USD")
        }
        return configuration.price(for: product)
    }

    /// Whether print should be entitled to a guest at all under this
    /// configuration. Under sponsored/promotional, print is either free
    /// (host's package included it) or entirely unavailable — it can never
    /// become a guest-paid upsell in those modes.
    static func printAvailable(in configuration: EventConfiguration) -> Bool {
        guard configuration.printingEnabled else { return false }
        if guestsAreNeverCharged(under: configuration.operatingMode) {
            return configuration.printingIncludedForGuests
        }
        return true // self-serve/hybrid: included free or offered as a paid upsell
    }

    /// Validates every hard domain invariant. Returns every violation found
    /// (not just the first) so an editor can surface them all at once.
    static func validate(_ configuration: EventConfiguration) -> [EventConfigurationValidationError] {
        var errors: [EventConfigurationValidationError] = []

        if guestsAreNeverCharged(under: configuration.operatingMode) {
            for product in BoothProduct.allCases {
                if let price = configuration.productPricing[product], !price.isFree {
                    errors.append(.guestPaymentUnderFreeMode(product: product))
                }
            }
        }

        if !configuration.digitalDeliveryEnabled && !configuration.printingEnabled && !configuration.availableExperiences.isEmpty {
            errors.append(.noDeliveryMechanismAvailable)
        }

        if let cta = configuration.socialCTA, cta.profileURL.scheme == nil || cta.profileURL.host == nil {
            errors.append(.invalidSocialURL)
        }

        let colorFields: [(String, String)] = [
            ("Primary Color", configuration.theme.primaryColorHex),
            ("Secondary Color", configuration.theme.secondaryColorHex),
            ("Accent Color", configuration.theme.accentColorHex),
        ]
        for (field, value) in colorFields where !HexColor.isValid(value) {
            errors.append(.invalidColor(field: field, value: value))
        }

        if configuration.mediaRetentionPolicy.duration <= 0 {
            errors.append(.invalidRetentionDuration)
        }

        return errors
    }
}
