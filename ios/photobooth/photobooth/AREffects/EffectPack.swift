//
//  EffectPack.swift
//  photobooth
//
//  Pure organization/filtering around existing EffectDefinition objects —
//  not a second rendering engine. A pack is just a named, ordered subset of
//  effect IDs (e.g. a seasonal Halloween lineup); resolving it to actual
//  EffectDefinitions still goes through EffectCatalog, and rendering still
//  goes through EffectCompositor/EffectPlacementEngine exactly as before.
//
//  Membership is by `EffectDefinition.id`, not by reference, so an effect
//  (Playful Pup) can belong to the always-available default catalog AND a
//  seasonal pack at the same time.
//

struct EffectPack: Identifiable, Equatable {
    let id: String
    var displayName: String
    /// Declared display order for this pack — deliberately not
    /// `EffectCatalog.all`'s order, so a pack fully controls what guests
    /// see and in what sequence.
    var effectIDs: [String]

    /// Resolves `effectIDs` into their `EffectDefinition`s. Unknown IDs are
    /// silently skipped rather than crashing — a typo'd/removed effect ID
    /// should never take down effect selection for an event.
    var effects: [EffectDefinition] {
        effectIDs.compactMap { id in EffectCatalog.allIncludingSeasonal.first { $0.id == id } }
    }
}

enum EffectPackCatalog {
    /// Pacific Horizon Labs' October 3, 2026 promotional event.
    static let halloween2026 = EffectPack(
        id: "halloween-2026",
        displayName: "Halloween",
        effectIDs: [
            EffectCatalog.werewolfRage.id,
            EffectCatalog.darkVampire.id,
            EffectCatalog.enchantedPixie.id,
            EffectCatalog.phantomSlasher.id,
            EffectCatalog.devilMode.id,
            EffectCatalog.playfulPup.id,
        ]
    )

    /// Every definable pack. Adding a future event's pack means adding one
    /// entry here, not touching the guest-facing selection code.
    static let all: [EffectPack] = [halloween2026]
}
