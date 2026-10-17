//
//  PhotoFrameCompositor.swift
//  photobooth
//
//  Bakes the guest's selected PhotoFrame (if any) onto accepted media — the
//  last compositing step, on top of any Portal scene/AR effect, so it always
//  reads as a border around the final image. Uses the same
//  UIGraphicsImageRenderer draw-on-top technique as EffectCompositor, just
//  without that pipeline's face-detection/face-anchoring requirement: a
//  border frame must appear whether or not a face was found in the shot.
//
//  Two entry points, exactly mirroring EffectCompositor's own
//  UIImage-for-stills / CGImage-for-Loop-frames split, sharing one piece of
//  geometry math so both paths can never drift apart:
//    - `composite(frame:into:)` — one-shot still photo bake.
//    - `compositeFrame(_:frame:)` — per-frame Loop/boomerang bake, called
//      once per already-downscaled frame from LoopCapturePipeline.ingest.
//

import UIKit

enum PhotoFrameCompositor {
    /// Draws `frame`'s art over `image` using aspect-fill ("cover") scaling
    /// — the same uniform-scale-then-center-crop geometry CameraPreview's
    /// `.resizeAspectFill` and the live preview overlay already use, so the
    /// border's proportions match what the guest saw live rather than a
    /// non-uniform X/Y stretch to the photo's own aspect ratio. The PNG
    /// itself is never modified, only scaled (uniformly) and cropped like
    /// any other cover-fit image in this app. `frame == nil` (no frame
    /// selected) or a missing/unloadable asset both fail open to the
    /// original image untouched — capture must never fail because a frame
    /// did.
    static func composite(frame: PhotoFrame?, into image: UIImage) -> UIImage {
        debugLog("selected ID: \(frame?.id ?? "nil")")
        guard let frame else { return image }

        let overlay = UIImage(named: frame.assetName)
        debugLog("resolved asset: \(frame.assetName)")
        debugLog("UIImage loaded: \(overlay != nil)")
        guard let overlay, let drawRect = coverFitRect(overlaySize: overlay.size, canvasSize: image.size) else { return image }

        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in
            image.draw(at: .zero)
            overlay.draw(in: drawRect)
        }
    }

    /// Same bake, for one already-downscaled Loop/boomerang frame. Called
    /// once per captured frame (see LoopCapturePipeline.ingest) — cheap
    /// relative to AR effect compositing or segmentation, since this is
    /// just one more plain draw call, no Vision/analysis work of its own.
    /// Fails open to `cgImage` untouched on any missing frame/asset, same
    /// as the still-photo path — a Loop recording must never abort because
    /// a frame did.
    static func compositeFrame(_ cgImage: CGImage, frame: PhotoFrame?) -> CGImage {
        guard let frame, let overlay = UIImage(named: frame.assetName) else { return cgImage }

        let canvasSize = CGSize(width: cgImage.width, height: cgImage.height)
        guard let drawRect = coverFitRect(overlaySize: overlay.size, canvasSize: canvasSize) else { return cgImage }

        let baseImage = UIImage(cgImage: cgImage)
        let format = UIGraphicsImageRendererFormat()
        format.scale = baseImage.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
        let composited = renderer.image { _ in
            baseImage.draw(at: .zero)
            overlay.draw(in: drawRect)
        }
        return composited.cgImage ?? cgImage
    }

    /// Cover-fit ("aspect-fill") geometry shared by both entry points above:
    /// one uniform scale factor (never separate X/Y factors) sized so the
    /// overlay fully covers `canvasSize`, then centered — any overflow is
    /// simply outside the renderer's fixed-size bitmap context and is never
    /// captured, i.e. a free center-crop with no explicit clip path needed.
    /// `nil` for a degenerate (zero-sized) overlay/canvas.
    private static func coverFitRect(overlaySize: CGSize, canvasSize: CGSize) -> CGRect? {
        guard overlaySize.width > 0, overlaySize.height > 0,
              canvasSize.width > 0, canvasSize.height > 0 else { return nil }

        let coverScale = max(canvasSize.width / overlaySize.width, canvasSize.height / overlaySize.height)
        let drawnSize = CGSize(width: overlaySize.width * coverScale, height: overlaySize.height * coverScale)
        return CGRect(
            x: (canvasSize.width - drawnSize.width) / 2,
            y: (canvasSize.height - drawnSize.height) / 2,
            width: drawnSize.width,
            height: drawnSize.height
        )
    }

    /// DEBUG-only — never compiled into Release. No secrets here, just the
    /// frame id/asset name (already guest-visible as a display name in the
    /// admin picker), so this is safe to leave in for the rest of this
    /// event in case tonight's behavior needs a second look.
    private static func debugLog(_ message: String) {
        #if DEBUG
        print("[Frame] \(message)")
        #endif
    }
}
