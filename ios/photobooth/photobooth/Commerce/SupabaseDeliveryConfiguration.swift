//
//  SupabaseDeliveryConfiguration.swift
//  photobooth
//
//  Runtime (never hardcoded) configuration for the Supabase delivery
//  backend. Every value here is safe to ship on-device — this is
//  deliberately the PUBLIC half of the Supabase key model:
//
//  - projectURL: your project's base URL (e.g. https://<ref>.supabase.co).
//    Public — it's just an address.
//  - publishableKey: the Supabase "anon"/publishable key. Public by design;
//    Supabase's security model relies on RLS + Edge Functions to restrict
//    what that key can actually do, not on keeping it secret.
//  - publicClaimBaseURL: the guest-facing claim landing page's base URL.
//    Public — it's shown in a QR code.
//
//  None of these is the Supabase *service role* secret key. That key must
//  NEVER appear on-device, in source, or in Git — it belongs only in
//  Supabase Edge Function environment secrets. See backend/supabase/README.md.
//
//  Loaded from an optional local plist that is explicitly excluded from Git
//  (see .gitignore) — the production runtime falls back to
//  UnconfiguredDeliveryService whenever this file doesn't exist, which is
//  the correct, safe default until Hector provisions a real backend.
//

import Foundation

struct SupabaseDeliveryConfiguration: Codable, Equatable {
    var projectURL: URL
    var publishableKey: String
    var publicClaimBaseURL: URL
}

enum SupabaseDeliveryConfigurationLoader {
    /// Looks for `SupabaseDeliveryConfig.plist` in the app bundle. This file
    /// is never committed — see backend/supabase/README.md for the exact
    /// local-only file Hector creates once a Supabase project exists.
    static func load() -> SupabaseDeliveryConfiguration? {
        guard let url = Bundle.main.url(forResource: "SupabaseDeliveryConfig", withExtension: "plist"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListDecoder().decode(SupabaseDeliveryConfiguration.self, from: data)
    }
}

enum DeliveryServiceFactory {
    /// The safe default everywhere BoothFlow is constructed: a real backend
    /// only if configured, otherwise the honest "not configured" fallback.
    static func makeDefault() -> DigitalDeliveryService {
        guard let configuration = SupabaseDeliveryConfigurationLoader.load() else {
            return UnconfiguredDeliveryService()
        }
        return SupabaseDeliveryService(configuration: configuration)
    }
}
