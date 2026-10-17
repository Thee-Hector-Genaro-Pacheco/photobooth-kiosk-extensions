//
//  EffectPlacementEngine.swift
//  photobooth
//
//  Single source of truth for turning (NormalizedFaceState, EffectElement)
//  into on-screen geometry. Used by both the live SwiftUI overlay and the
//  still-image compositor so there is exactly one placement implementation.
//

import CoreGraphics

/// Maps points normalized to `sourceSize` onto a `canvasSize` using
/// aspect-fill ("cover") scaling — the same behavior as the camera preview's
/// `.resizeAspectFill` video gravity, so live face geometry lines up with
/// what's on screen even though the two rectangles differ in aspect ratio.
struct CoverFitGeometry {
    let sourceSize: CGSize
    let scale: CGFloat
    let offset: CGPoint

    init(sourceSize: CGSize, canvasSize: CGSize) {
        self.sourceSize = sourceSize
        guard sourceSize.width > 0, sourceSize.height > 0,
              canvasSize.width > 0, canvasSize.height > 0 else {
            scale = 1
            offset = .zero
            return
        }
        let fitScale = max(canvasSize.width / sourceSize.width, canvasSize.height / sourceSize.height)
        scale = fitScale
        offset = CGPoint(
            x: (canvasSize.width - sourceSize.width * fitScale) / 2,
            y: (canvasSize.height - sourceSize.height * fitScale) / 2
        )
    }

    func point(forNormalized p: CGPoint) -> CGPoint {
        CGPoint(x: offset.x + p.x * sourceSize.width * scale, y: offset.y + p.y * sourceSize.height * scale)
    }

    /// `normalizedLength` is a fraction of `sourceSize.width` (see
    /// `NormalizedFaceState.interEyeDistance` / `mouthWidth`).
    func length(forNormalizedLength normalizedLength: CGFloat) -> CGFloat {
        normalizedLength * sourceSize.width * scale
    }
}

struct EffectPlacement {
    var center: CGPoint
    var size: CGSize
    var rotationRadians: CGFloat
}

enum EffectPlacementEngine {
    /// Resolves where/how large/how rotated a single effect element should be
    /// drawn. Returns `nil` when the element's visibility rule isn't met.
    static func placement(
        for element: EffectElement,
        face: NormalizedFaceState,
        geometry: CoverFitGeometry,
        assetPixelSize: CGSize
    ) -> EffectPlacement? {
        if let visibility = element.visibility, !visibility.isSatisfied(by: face) {
            return nil
        }
        guard assetPixelSize.width > 0, assetPixelSize.height > 0 else { return nil }

        let anchorScreen = geometry.point(forNormalized: element.anchor.point(in: face))

        let referenceLength = element.scaleReference.length(in: face)
        let targetWidth = max(10, geometry.length(forNormalizedLength: referenceLength) * element.scaleFactor)

        let aspect = assetPixelSize.height / assetPixelSize.width
        let heightMultiplier = element.reactiveHeight?.heightMultiplier(for: face) ?? 1.0
        let targetHeight = max(5, targetWidth * aspect * heightMultiplier)

        let roll = face.rollRadians
        let cosR = cos(roll)
        let sinR = sin(roll)
        // Unit vectors along the eye line and "up" the face, in the same
        // top-left/y-down screen space as everything else here.
        let uEyes = CGVector(dx: cosR, dy: sinR)
        let uUp = CGVector(dx: sinR, dy: -cosR)

        let offsetEyes = element.offsetAlongEyes * targetWidth
        let offsetUp = element.offsetAlongUp * targetHeight
        let targetFace = CGPoint(
            x: anchorScreen.x + uEyes.dx * offsetEyes + uUp.dx * offsetUp,
            y: anchorScreen.y + uEyes.dy * offsetEyes + uUp.dy * offsetUp
        )

        // Solve for the asset's geometric center such that rotating the asset
        // around that center pins its anatomical anchor at `targetFace`.
        let dax = (0.5 - element.assetAnchor.x) * targetWidth
        let day = (0.5 - element.assetAnchor.y) * targetHeight
        let center = CGPoint(
            x: targetFace.x + uEyes.dx * dax - uUp.dx * day,
            y: targetFace.y + uEyes.dy * dax - uUp.dy * day
        )

        return EffectPlacement(center: center, size: CGSize(width: targetWidth, height: targetHeight), rotationRadians: roll)
    }
}
