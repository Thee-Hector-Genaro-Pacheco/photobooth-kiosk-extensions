//
//  CinematicSceneCompositor.swift
//  photobooth
//
//  One compositing function, shared by the live preview engine
//  (CinematicSceneEngine) and Loop frame-by-frame baking (see
//  LoopCapturePipeline.ingest), same "one code path for both" pattern
//  PortalCompositor and EffectCompositor each already use internally, so
//  live preview and captured output can never drift apart.
//
//  NEVER discards the real camera frame and NEVER fails outright — this
//  function always returns at least the untouched real frame. Every
//  guard below is a fail-open point: if segmentation didn't run, if a
//  layer/element asset is missing, or if the mask blend fails, the
//  result simply doesn't get that piece of AR, not a black/blank image.
//
//  `.preserveCamera` pipeline (what Dark Vampire uses):
//
//      real camera frame
//            -> triggered behind-subject AR layer(s) drawn onto it
//            -> real segmented guest composited back OVER that
//               (PortalCompositor.composite, unchanged, fully reused —
//               it just masks `person` over whatever `background` CIImage
//               it's given, which here is "the real frame with a
//               behind-subject layer already drawn on it" rather than a
//               synthetic scene)
//            -> face-tracked elements (EffectPlacementEngine.placement,
//               unchanged, fully reused)
//            -> optional foreground atmosphere
//
//  `.replaceBackground` (Portal-style full replacement) is kept for
//  architectural completeness — see CinematicScene.swift — and follows
//  the same face-element/foreground steps after a full scene swap
//  instead of an occlusion blend.
//

import CoreImage
import UIKit

enum CinematicSceneCompositor {
    /// Composites one frame. `realFrame` is the untouched camera pixel
    /// buffer, already rendered to a CGImage by the caller. `mask` is the
    /// optional Vision person-segmentation matte for that same frame —
    /// `nil` when segmentation wasn't run (either it failed, or the
    /// caller determined this frame's active layers don't need it at all,
    /// see `CinematicScene.needsSegmentation`). `faces` are the
    /// already-tracked faces for this frame (never re-run here, matching
    /// EffectCompositor.compositeFrame's existing convention).
    static func compositeFrame(
        realFrame: CGImage,
        mask: CIImage?,
        scene: CinematicScene,
        isTriggered: Bool,
        faces: [TrackedFaceState],
        context: CIContext
    ) -> CGImage {
        var resultCG = realFrame

        switch scene.backgroundPolicy {
        case .preserveCamera:
            let behindLayers = scene.behindSubjectLayers(isTriggered: isTriggered)
            if !behindLayers.isEmpty, let mask {
                let withBehind = Self.drawLayers(behindLayers, onto: realFrame)
                if let blended = PortalCompositor.composite(
                    person: CIImage(cgImage: realFrame),
                    mask: mask,
                    background: CIImage(cgImage: withBehind),
                    edgeTint: scene.edgeTint,
                    context: context
                ) {
                    resultCG = blended
                }
                // else: mask/compositing failed this frame — resultCG
                // stays the untouched real frame (fail open).
            }
            // No behind-subject layers active this frame, or no mask
            // available: resultCG is simply the real frame, unmodified,
            // exactly the fail-open / "nothing to occlude" case.

        case .replaceBackground(let resting, let triggered):
            let backgroundName = isTriggered ? triggered.assetName : resting.assetName
            if let mask, let bgImage = UIImage(named: backgroundName), let backgroundCI = CIImage(image: bgImage) {
                if let blended = PortalCompositor.composite(
                    person: CIImage(cgImage: realFrame),
                    mask: mask,
                    background: backgroundCI,
                    edgeTint: scene.edgeTint,
                    context: context
                ) {
                    resultCG = blended
                }
            }
            // Missing art or missing mask: fail open to the real frame —
            // same as `.preserveCamera`, never a fabricated void.
        }

        resultCG = Self.drawFaceElements(scene.faceElements(isTriggered: isTriggered), onto: resultCG, faces: faces)
        resultCG = Self.drawLayers(scene.foregroundLayers(isTriggered: isTriggered), onto: resultCG)

        return resultCG
    }

    /// Draws AR layers at their normalized placement rect with plain Core
    /// Graphics — the same top-left/y-down drawing convention every other
    /// asset placement in this app already uses (EffectCompositor,
    /// EffectOverlayView), so a layer's placement rect means the same
    /// thing here as everywhere else. A missing asset is skipped, not a
    /// failure — the rest of the frame still renders.
    private static func drawLayers(_ layers: [CinematicLayer], onto cgImage: CGImage) -> CGImage {
        guard !layers.isEmpty else { return cgImage }
        let baseImage = UIImage(cgImage: cgImage)
        let format = UIGraphicsImageRendererFormat()
        format.scale = baseImage.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: baseImage.size, format: format)
        let drawn = renderer.image { _ in
            baseImage.draw(at: .zero)
            for layer in layers {
                guard let asset = UIImage(named: layer.assetName) else { continue }
                let rect = CGRect(
                    x: layer.placement.minX * baseImage.size.width,
                    y: layer.placement.minY * baseImage.size.height,
                    width: layer.placement.width * baseImage.size.width,
                    height: layer.placement.height * baseImage.size.height
                )
                asset.draw(in: rect, blendMode: .normal, alpha: layer.opacity)
            }
        }
        return drawn.cgImage ?? cgImage
    }

    private static func drawFaceElements(_ elements: [EffectElement], onto cgImage: CGImage, faces: [TrackedFaceState]) -> CGImage {
        guard !elements.isEmpty, !faces.isEmpty, let sourceSize = faces.first?.faceState.sourceSize,
              sourceSize.width > 0, sourceSize.height > 0 else { return cgImage }

        let baseImage = UIImage(cgImage: cgImage)
        let geometry = CoverFitGeometry(sourceSize: sourceSize, canvasSize: baseImage.size)
        let format = UIGraphicsImageRendererFormat()
        format.scale = baseImage.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: baseImage.size, format: format)
        let drawn = renderer.image { ctx in
            baseImage.draw(at: .zero)
            let cg = ctx.cgContext
            for tracked in faces {
                let face = tracked.faceState
                for element in elements {
                    guard let asset = UIImage(named: element.assetName),
                          let placement = EffectPlacementEngine.placement(
                            for: element, face: face, geometry: geometry, assetPixelSize: asset.size
                          ) else { continue }
                    cg.saveGState()
                    cg.translateBy(x: placement.center.x, y: placement.center.y)
                    cg.rotate(by: placement.rotationRadians)
                    asset.draw(in: CGRect(
                        x: -placement.size.width / 2, y: -placement.size.height / 2,
                        width: placement.size.width, height: placement.size.height
                    ))
                    cg.restoreGState()
                }
            }
        }
        return drawn.cgImage ?? cgImage
    }
}
