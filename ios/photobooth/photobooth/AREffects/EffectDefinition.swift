//
//  EffectDefinition.swift
//  photobooth
//
//  Data-driven AR effect model. Mirrors the semantics of the browser/Pi
//  prototype's AR_EFFECT_CONFIGS (scripts/ar_engine.py) so effects are
//  configuration, not per-effect Swift code.
//

import CoreGraphics

enum EffectAnchor {
    case eyesCenter
    case foreheadAnchor
    case noseAnchor
    case mouthAnchor

    func point(in face: NormalizedFaceState) -> CGPoint {
        switch self {
        case .eyesCenter: face.eyeCenter
        case .foreheadAnchor: face.foreheadAnchor
        case .noseAnchor: face.noseAnchor
        case .mouthAnchor: face.mouthAnchor
        }
    }
}

enum EffectScaleReference {
    case interEyeDistance
    case mouthWidth

    /// Normalized (fraction of source width) reference length for this face.
    func length(in face: NormalizedFaceState) -> CGFloat {
        switch self {
        case .interEyeDistance:
            face.interEyeDistance
        case .mouthWidth:
            face.mouthWidth > 0 ? face.mouthWidth : face.interEyeDistance
        }
    }
}

/// Declarative visibility gate. Only one condition is needed for this
/// milestone (mouth open/closed), kept generic so more can be added without
/// touching the renderer.
struct EffectVisibilityRule: Equatable {
    var mouthOpenEquals: Bool

    func isSatisfied(by face: NormalizedFaceState) -> Bool {
        face.mouthOpen == mouthOpenEquals
    }
}

/// Maps a continuous expression value (currently always mouth ratio) onto a
/// vertical scale multiplier, e.g. to make a tongue extend as the mouth opens.
struct EffectReactiveHeight: Equatable {
    var inputMin: CGFloat
    var inputMax: CGFloat
    var minScale: CGFloat
    var maxScale: CGFloat

    func heightMultiplier(for face: NormalizedFaceState) -> CGFloat {
        let denom = inputMax - inputMin
        guard denom > 0.0001 else { return minScale }
        let t = min(1, max(0, (face.mouthRatio - inputMin) / denom))
        return minScale + t * (maxScale - minScale)
    }
}

/// One visual layer of an effect (e.g. Playful Pup's ears, muzzle, and tongue
/// are three separate elements sharing the same effect id).
struct EffectElement: Identifiable {
    let id = UUID()
    var assetName: String
    var anchor: EffectAnchor
    /// Anatomical anchor point within the asset image, normalized 0...1.
    var assetAnchor: CGPoint
    var scaleReference: EffectScaleReference
    var scaleFactor: CGFloat
    var offsetAlongEyes: CGFloat = 0
    var offsetAlongUp: CGFloat = 0
    var visibility: EffectVisibilityRule?
    var reactiveHeight: EffectReactiveHeight?
}

struct EffectDefinition: Identifiable, Equatable {
    static func == (lhs: EffectDefinition, rhs: EffectDefinition) -> Bool { lhs.id == rhs.id }

    let id: String
    var displayName: String
    var elements: [EffectElement]
}
