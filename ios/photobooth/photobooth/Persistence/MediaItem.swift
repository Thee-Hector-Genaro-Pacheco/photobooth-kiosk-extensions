//
//  MediaItem.swift
//  photobooth
//
//  A single piece of persisted guest media. Deliberately stores only a
//  filename, not an absolute URL — the app sandbox's container path isn't
//  guaranteed stable across launches/app updates, so persisting an absolute
//  path would be fragile. SessionRepository resolves `filename` against the
//  session's current directory at runtime (see `resolvedURL(for:in:)`).
//

import Foundation

struct MediaItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case photo
        case loopVideo
        // Room to add `printRender` later without touching existing data.
    }

    let id: UUID
    let kind: Kind
    let filename: String
    let createdAt: Date
    let mimeType: String
}
