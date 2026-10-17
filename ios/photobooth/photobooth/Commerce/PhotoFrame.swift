//
//  PhotoFrame.swift
//  photobooth
//
//  A static, full-bleed border image baked onto an accepted still photo —
//  e.g. an event-branded frame print would use. No frame/border pipeline
//  existed in this app before this file: `EventTheme.framePackReference`
//  was inert data (see its own doc comment — "no frame renderer... yet"),
//  and the only other static-art compositor in the app, EffectCompositor,
//  requires a detected face and anchors art to face landmarks — both wrong
//  for a border that must appear around the whole photo regardless of
//  whether a face was found. This is the smallest new type that does the
//  right thing instead of forcing a face-anchored pipeline to do a job it
//  wasn't built for.
//
//  Mirrors EffectPack/EffectPackCatalog's own shape on purpose (a plain
//  catalog of value types, resolved by id, never a second rendering
//  engine) so this reads as the same kind of thing to anyone already
//  familiar with that pattern.
//

import Foundation

struct PhotoFrame: Identifiable, Equatable {
    let id: String
    var displayName: String
    var assetName: String
}

enum PhotoFrameCatalog {
    static let big50 = PhotoFrame(
        id: "frame-big-50",
        displayName: "Celebrating the Big 50!",
        assetName: "frame-big-50"
    )

    /// Every definable frame. Adding a future frame means adding one entry
    /// here, not touching selection or compositing code.
    static let all: [PhotoFrame] = [big50]
}
