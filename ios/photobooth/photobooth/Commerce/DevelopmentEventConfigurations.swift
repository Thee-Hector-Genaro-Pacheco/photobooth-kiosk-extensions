//
//  DevelopmentEventConfigurations.swift
//  photobooth
//
//  DEBUG-only fixtures for previews, tests, and the admin editor's "load a
//  starter template" convenience buttons. Never compiled into a Release
//  build, and never applied automatically — the production runtime obtains
//  its event from EventConfigurationStore, defaulting to a safe
//  "configuration required" state when none exists (see BoothFlow/
//  ContentView). All names/handles/URLs below are obviously synthetic
//  preview data, not real business information.
//

#if DEBUG
import Foundation

enum DevelopmentEventConfigurations {
    /// A. Sponsored — an organization is paying; guests aren't charged.
    static let sponsored = EventConfiguration(
        id: UUID(),
        name: "Preview Sponsored Event",
        operatingMode: .sponsored,
        availableExperiences: [.classic, .arParty, .loopClip],
        productPricing: [:],
        printingEnabled: true,
        printingIncludedForGuests: true,
        digitalDeliveryEnabled: true,
        socialCTA: nil,
        mediaRetentionPolicy: .hours(72),
        theme: EventTheme(
            displayTitle: "Preview Event",
            displaySubtitle: "Sample sponsored configuration",
            primaryColorHex: EventTheme.none.primaryColorHex,
            secondaryColorHex: EventTheme.none.secondaryColorHex,
            accentColorHex: EventTheme.none.accentColorHex,
            logoAssetReference: nil,
            framePackReference: nil,
            designNotes: "Preview/test fixture — not real event data."
        )
    )

    /// B. Self-serve — no event contract; guests pay per product.
    static let selfServe = EventConfiguration(
        id: UUID(),
        name: "Preview Self-Serve Event",
        operatingMode: .selfServe,
        availableExperiences: [.classic, .arParty, .loopClip],
        productPricing: [
            .digitalPhoto: Money(amountInMinorUnits: 300, currencyCode: "USD"),
            .loopVideo: Money(amountInMinorUnits: 400, currencyCode: "USD"),
            .print4x6: Money(amountInMinorUnits: 600, currencyCode: "USD"),
            .digitalAndPrint: Money(amountInMinorUnits: 800, currencyCode: "USD"),
        ],
        printingEnabled: true,
        printingIncludedForGuests: false,
        digitalDeliveryEnabled: true,
        socialCTA: nil,
        mediaRetentionPolicy: .hours(24),
        theme: EventTheme.none
    )

    /// C. Hybrid — digital is free, print costs money.
    static let hybrid = EventConfiguration(
        id: UUID(),
        name: "Preview Hybrid Event",
        operatingMode: .hybrid,
        availableExperiences: [.classic, .arParty, .loopClip],
        productPricing: [
            .print4x6: Money(amountInMinorUnits: 500, currencyCode: "USD"),
        ],
        printingEnabled: true,
        printingIncludedForGuests: false,
        digitalDeliveryEnabled: true,
        socialCTA: nil,
        mediaRetentionPolicy: .hours(72),
        theme: EventTheme.none
    )

    /// D. Promotional — free media, optional social follow/tag prompt using
    /// an obviously synthetic handle/URL (never a real account).
    static let promotional = EventConfiguration(
        id: UUID(),
        name: "Preview Promotional Event",
        operatingMode: .promotional,
        availableExperiences: [.classic, .arParty, .loopClip],
        productPricing: [:],
        printingEnabled: false,
        printingIncludedForGuests: false,
        digitalDeliveryEnabled: true,
        socialCTA: SocialCTA(
            platform: .instagram,
            displayName: "@preview_handle",
            profileURL: URL(string: "https://example.com/preview-handle")!,
            message: "Preview fixture — tag us in your post to be featured."
        ),
        mediaRetentionPolicy: .hours(72),
        theme: EventTheme.none
    )
}
#endif
