//
//  ClaimTokenGenerator.swift
//  photobooth
//
//  The public delivery secret (future URL: https://<domain>/s/<claim-token>)
//  must be an unguessable random value, never a UUID, event ID, timestamp,
//  or incrementing number — those are either predictable or not secret at
//  all. Generated via Apple's secure random facility (Security framework),
//  not a general-purpose PRNG.
//

import Foundation
import Security

enum ClaimTokenGenerator {
    enum GenerationError: Error {
        case failed
    }

    /// 24 random bytes (192 bits) URL-safe base64-encoded, suitable as a
    /// single path segment.
    static func generate(byteCount: Int = 24) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        guard status == errSecSuccess else { throw GenerationError.failed }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
