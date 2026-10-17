//
//  BoothAuthHashSelfTest.swift
//  photobooth
//
//  DEBUG-only regression guard for the client/server hashing boundary.
//  Hashes the exact same known fixture string as
//  backend/supabase/functions/_shared/boothAuth.test.ts and compares
//  against the identical hardcoded expected value, so a future change to
//  either implementation that breaks agreement between
//  BoothDeviceIdentityStore.sha256Hex(ofUTF8String:) and boothAuth.ts's
//  sha256Hex fails loudly (a printed mismatch) instead of silently
//  producing 403s again. Not a production credential.
//

import Foundation

#if DEBUG
enum BoothAuthHashSelfTest {
    static let knownTestToken = "known-test-token-do-not-use-in-production"
    // Must stay identical to boothAuth.test.ts's EXPECTED_SHA256_HEX.
    static let expectedSHA256Hex = "90c2be4a841f5003c1b1bb136ccf8a7a688d7591e67bbebc19e31d1fdf08feaf"

    /// Call once at app launch in DEBUG builds. Returns whether it passed;
    /// always logs the result (never a secret — this is a fixed public
    /// test string, not a real device token).
    @discardableResult
    static func run() -> Bool {
        let hash = BoothDeviceIdentityStore.sha256Hex(ofUTF8String: knownTestToken)
        let matches = hash == expectedSHA256Hex
        if matches {
            print("[BoothAuthHashSelfTest] OK — Swift/TypeScript hashing agree")
        } else {
            print("[BoothAuthHashSelfTest] MISMATCH — expected \(expectedSHA256Hex) got \(hash). Client/server hashing has drifted apart.")
        }
        return matches
    }
}
#endif
