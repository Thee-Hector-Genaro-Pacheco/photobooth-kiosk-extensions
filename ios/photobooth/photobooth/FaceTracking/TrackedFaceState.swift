//
//  TrackedFaceState.swift
//  photobooth
//
//  Pairs a tracker-agnostic NormalizedFaceState with a short-lived identity
//  stable across frames within one camera session, so live rendering can
//  tell "the same face as last frame" apart from "a new face" without any
//  biometric identity — just frame-to-frame association.
//

import Foundation

struct TrackedFaceState: Identifiable, Equatable {
    let id: Int
    var faceState: NormalizedFaceState
}
