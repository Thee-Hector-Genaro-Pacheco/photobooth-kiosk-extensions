//
//  PaymentProvider.swift
//  photobooth
//
//  Payment is a boundary the iPad app talks to, never a fact it decides for
//  itself. No implementation here ever sets a guest's payment to "paid" —
//  that must eventually come from a server-authoritative source (iPad ->
//  backend -> payment provider -> webhook -> backend -> entitlement). This
//  phase only introduces the shapes and the two safe defaults (nothing to
//  pay, and nothing configured to pay with).
//

import Foundation

enum PaymentState: String, Codable, Equatable {
    case notRequired
    case pending
    case paid
    case failed
    case cancelled
}

enum PaymentError: LocalizedError {
    case providerNotConfigured

    var errorDescription: String? {
        switch self {
        case .providerNotConfigured:
            "No payment provider is configured for this event. An administrator needs to set one up before this product can be sold."
        }
    }
}

protocol PaymentProvider {
    /// Starts checkout for `products` and returns the resulting state. Real
    /// implementations must not resolve to `.paid` synchronously from a
    /// button press — that state has to come back from a server that
    /// actually verified payment.
    func createCheckout(for session: BoothSession, products: [BoothProduct]) async throws -> PaymentState
    func paymentStatus(for session: BoothSession) async -> PaymentState
}

/// Used whenever a product's price is free (sponsored/promotional events, or
/// a free product within a hybrid event) — there is nothing to pay, by
/// design, not because payment was skipped.
struct SponsoredPaymentProvider: PaymentProvider {
    func createCheckout(for session: BoothSession, products: [BoothProduct]) async throws -> PaymentState {
        .notRequired
    }

    func paymentStatus(for session: BoothSession) async -> PaymentState {
        .notRequired
    }
}

/// A paid product was requested but no real payment provider (Square,
/// Stripe, etc.) has been wired up yet. Always fails loudly rather than
/// granting a paid entitlement the guest never paid for.
struct UnconfiguredPaymentProvider: PaymentProvider {
    func createCheckout(for session: BoothSession, products: [BoothProduct]) async throws -> PaymentState {
        throw PaymentError.providerNotConfigured
    }

    func paymentStatus(for session: BoothSession) async -> PaymentState {
        .failed
    }
}
