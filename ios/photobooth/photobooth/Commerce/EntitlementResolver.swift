//
//  EntitlementResolver.swift
//  photobooth
//
//  Turns "guest wants product X under event config Y" into a payment state +
//  resulting entitlements + which PaymentProvider to use. Defers every
//  charge/availability decision to EventPolicy rather than reading
//  `productPricing`/`printingEnabled` directly — that's what guarantees a
//  sponsored event can never end up routing a guest to checkout even if its
//  pricing data is mis-entered.
//

import Foundation

enum EntitlementResolver {
    struct Resolution {
        let paymentState: PaymentState
        let entitlements: Set<Entitlement>
        let provider: PaymentProvider
    }

    static func resolve(product: BoothProduct, configuration: EventConfiguration) -> Resolution {
        guard EventPolicy.guestMayBeCharged(for: product, in: configuration) else {
            // Free by configuration, or a mode where guests are never
            // charged (sponsored/promotional) regardless of raw pricing —
            // either way, no PaymentProvider that could charge a guest is
            // ever invoked here.
            return Resolution(paymentState: .notRequired, entitlements: entitlements(for: product, configuration: configuration), provider: SponsoredPaymentProvider())
        }
        // Paid product under self-serve/hybrid: entitlements are withheld
        // until a real payment provider confirms payment — not implemented
        // this phase, so this always surfaces as pending -> provider error.
        return Resolution(paymentState: .pending, entitlements: [], provider: UnconfiguredPaymentProvider())
    }

    private static func entitlements(for product: BoothProduct, configuration: EventConfiguration) -> Set<Entitlement> {
        switch product {
        case .digitalPhoto:
            [.downloadPhoto]
        case .loopVideo:
            [.downloadLoop]
        case .print4x6:
            EventPolicy.printAvailable(in: configuration) ? [.printPhoto] : []
        case .digitalAndPrint:
            EventPolicy.printAvailable(in: configuration) ? [.downloadPhoto, .printPhoto] : [.downloadPhoto]
        }
    }
}
