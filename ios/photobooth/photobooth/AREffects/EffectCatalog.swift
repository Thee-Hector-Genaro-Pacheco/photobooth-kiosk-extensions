//
//  EffectCatalog.swift
//  photobooth
//
//  Concrete effect definitions. Numeric placement values are ported directly
//  from the Raspberry Pi/browser reference implementation's
//  AR_EFFECT_CONFIGS (scripts/ar_engine.py) so on-screen behavior matches the
//  existing, already-tuned prototype.
//

import CoreGraphics

enum EffectCatalog {
    static let none = EffectDefinition(id: "none", displayName: "None", elements: [])

    static let glasses = EffectDefinition(
        id: "glasses",
        displayName: "Glasses",
        elements: [
            EffectElement(
                assetName: "ar-glasses",
                anchor: .eyesCenter,
                assetAnchor: CGPoint(x: 0.50, y: 0.38),
                scaleReference: .interEyeDistance,
                scaleFactor: 2.05
            )
        ]
    )

    static let crown = EffectDefinition(
        id: "crown",
        displayName: "Crown",
        elements: [
            EffectElement(
                assetName: "ar-crown",
                anchor: .foreheadAnchor,
                assetAnchor: CGPoint(x: 0.50, y: 1.00),
                scaleReference: .interEyeDistance,
                scaleFactor: 2.40
            )
        ]
    )

    static let mustache = EffectDefinition(
        id: "mustache",
        displayName: "Mustache",
        elements: [
            EffectElement(
                assetName: "ar-mustache",
                anchor: .noseAnchor,
                assetAnchor: CGPoint(x: 0.50, y: 0.15),
                scaleReference: .interEyeDistance,
                scaleFactor: 1.35,
                offsetAlongUp: -0.35
            )
        ]
    )

    static let playfulPup = EffectDefinition(
        id: "playful_pup",
        displayName: "Pup",
        elements: [
            EffectElement(
                assetName: "ar-dog-ears",
                anchor: .foreheadAnchor,
                assetAnchor: CGPoint(x: 0.50, y: 0.75),
                scaleReference: .interEyeDistance,
                scaleFactor: 2.50,
                offsetAlongUp: 0.15
            ),
            EffectElement(
                assetName: "ar-dog-tongue",
                anchor: .mouthAnchor,
                assetAnchor: CGPoint(x: 0.50, y: 0.05),
                scaleReference: .mouthWidth,
                scaleFactor: 1.05,
                visibility: EffectVisibilityRule(mouthOpenEquals: true),
                reactiveHeight: EffectReactiveHeight(inputMin: 0.20, inputMax: 0.50, minScale: 0.40, maxScale: 1.25)
            ),
            EffectElement(
                assetName: "ar-dog-muzzle",
                anchor: .noseAnchor,
                assetAnchor: CGPoint(x: 0.50, y: 0.45),
                scaleReference: .interEyeDistance,
                scaleFactor: 1.40,
                offsetAlongUp: -0.10
            )
        ]
    )

    /// Order matches the guest-facing selector: NONE, GLASSES, CROWN, MUSTACHE, PUP.
    static let all: [EffectDefinition] = [none, glasses, crown, mustache, playfulPup]
}
