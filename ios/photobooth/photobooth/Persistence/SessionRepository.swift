//
//  SessionRepository.swift
//  photobooth
//
//  The only place that touches FileManager for guest sessions — views and
//  BoothFlow go through this, never through ad hoc file I/O of their own.
//
//  Layout inside Application Support (never Photos):
//
//    Application Support/PhotoBooth/Events/<event-id>/Sessions/<session-id>/
//      session.json
//      <media-file>...
//
//  Writes are atomic (temp-write-then-rename via `.atomic`), each session
//  gets its own UUID-named directory (no collisions), and media filenames
//  are UUID-based so re-adding media never overwrites an existing file.
//

import Foundation

enum SessionStoreError: LocalizedError {
    case sessionNotFound
    case writeFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .sessionNotFound: "The session could not be found."
        case .writeFailed: "The session could not be saved."
        }
    }
}

final class SessionRepository {
    private let fileManager = FileManager.default
    private let rootDirectory: URL

    init() {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        rootDirectory = appSupport.appendingPathComponent("PhotoBooth", isDirectory: true)
    }

    func sessionDirectory(eventID: UUID, sessionID: UUID) -> URL {
        rootDirectory
            .appendingPathComponent("Events/\(eventID.uuidString)/Sessions/\(sessionID.uuidString)", isDirectory: true)
    }

    func resolvedURL(for item: MediaItem, in session: BoothSession) -> URL {
        sessionDirectory(eventID: session.eventID, sessionID: session.id).appendingPathComponent(item.filename)
    }

    /// Copies `sourceURL` into the session's directory and appends the
    /// resulting `MediaItem` to `session.mediaItems`. Used for media that
    /// already exists on disk (e.g. a Loop's temporary .mov).
    @discardableResult
    func addMedia(kind: MediaItem.Kind, sourceURL: URL, mimeType: String, to session: inout BoothSession) throws -> MediaItem {
        let directory = sessionDirectory(eventID: session.eventID, sessionID: session.id)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let ext = sourceURL.pathExtension.isEmpty ? defaultExtension(for: kind) : sourceURL.pathExtension
        let filename = "\(UUID().uuidString).\(ext)"
        let destination = directory.appendingPathComponent(filename)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw SessionStoreError.writeFailed(underlying: CocoaError(.fileWriteFileExists))
        }
        try fileManager.copyItem(at: sourceURL, to: destination)

        let item = MediaItem(id: UUID(), kind: kind, filename: filename, createdAt: Date(), mimeType: mimeType)
        session.mediaItems.append(item)
        session.updatedAt = Date()
        return item
    }

    /// Writes in-memory data (e.g. JPEG bytes) directly into the session's
    /// directory, atomically.
    @discardableResult
    func addMedia(kind: MediaItem.Kind, data: Data, fileExtension: String, mimeType: String, to session: inout BoothSession) throws -> MediaItem {
        let directory = sessionDirectory(eventID: session.eventID, sessionID: session.id)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let filename = "\(UUID().uuidString).\(fileExtension)"
        let destination = directory.appendingPathComponent(filename)
        try data.write(to: destination, options: .atomic)

        let item = MediaItem(id: UUID(), kind: kind, filename: filename, createdAt: Date(), mimeType: mimeType)
        session.mediaItems.append(item)
        session.updatedAt = Date()
        return item
    }

    /// Persists `session.json` atomically.
    func save(_ session: BoothSession) throws {
        let directory = sessionDirectory(eventID: session.eventID, sessionID: session.id)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(session)
        try data.write(to: directory.appendingPathComponent("session.json"), options: .atomic)
    }

    func load(eventID: UUID, sessionID: UUID) throws -> BoothSession {
        let url = sessionDirectory(eventID: eventID, sessionID: sessionID).appendingPathComponent("session.json")
        guard fileManager.fileExists(atPath: url.path) else { throw SessionStoreError.sessionNotFound }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BoothSession.self, from: data)
    }

    /// Scans every persisted session across every event. Missing/corrupted
    /// `session.json` files are skipped rather than thrown, since a cleanup
    /// scan shouldn't fail outright over one bad file.
    func allSessions() -> [BoothSession] {
        let eventsRoot = rootDirectory.appendingPathComponent("Events", isDirectory: true)
        guard let eventDirs = try? fileManager.contentsOfDirectory(at: eventsRoot, includingPropertiesForKeys: nil) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var sessions: [BoothSession] = []
        for eventDir in eventDirs {
            let sessionsDir = eventDir.appendingPathComponent("Sessions", isDirectory: true)
            guard let sessionDirs = try? fileManager.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil) else { continue }
            for sessionDir in sessionDirs {
                guard let data = try? Data(contentsOf: sessionDir.appendingPathComponent("session.json")),
                      let session = try? decoder.decode(BoothSession.self, from: data) else { continue }
                sessions.append(session)
            }
        }
        return sessions
    }

    /// Deletes a session's entire directory (metadata + media). Not called
    /// automatically anywhere in the app — see MediaRetentionCleanupService.
    func delete(_ session: BoothSession) throws {
        let directory = sessionDirectory(eventID: session.eventID, sessionID: session.id)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }

    private func defaultExtension(for kind: MediaItem.Kind) -> String {
        switch kind {
        case .photo: "jpg"
        case .loopVideo: "mov"
        }
    }
}
