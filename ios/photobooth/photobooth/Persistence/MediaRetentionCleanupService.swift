//
//  MediaRetentionCleanupService.swift
//  photobooth
//
//  Boundary for future automated cleanup of expired guest media. Nothing in
//  the app calls `deleteExpiredSessions()` yet — automated destructive
//  cleanup requires explicit authorization we haven't been given. This
//  phase only stores expiration metadata (BoothSession.expirationDate) and
//  provides a way to find/act on it later.
//

import Foundation

protocol MediaRetentionCleanupService {
    /// Sessions whose `expirationDate` has passed. Read-only — does not
    /// delete anything.
    func expiredSessions() -> [BoothSession]
    /// Deletes one session's persisted media/metadata. Callers decide when
    /// (or whether) this ever runs.
    func deleteSession(_ session: BoothSession) throws
}

final class DefaultMediaRetentionCleanupService: MediaRetentionCleanupService {
    private let repository: SessionRepository

    init(repository: SessionRepository) {
        self.repository = repository
    }

    func expiredSessions() -> [BoothSession] {
        repository.allSessions().filter { $0.expirationDate < Date() }
    }

    func deleteSession(_ session: BoothSession) throws {
        try repository.delete(session)
    }
}
