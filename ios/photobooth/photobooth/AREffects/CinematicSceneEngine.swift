//
//  CinematicSceneEngine.swift
//  photobooth
//
//  Owns the live, throttled CinematicScene pipeline for AR Party effects
//  built on CinematicScene (currently Dark Vampire) — the same "fast
//  segmentation + compositor, run off the main actor, publish the latest
//  frame, drop frames while busy" shape as PortalEngine, applied to
//  CinematicSceneCompositor instead of PortalCompositor directly (which it
//  still calls into internally). Bounded by design, same as PortalEngine:
//  at most one frame in flight, never an unbounded backlog.
//
//  Fail-open, always: `compositeFrame` never returns nil, and this class
//  never publishes anything but a real, well-formed frame — worst case
//  (segmentation unavailable, or nothing to occlude this frame) is the
//  untouched real camera frame plus whatever face elements are active,
//  never a black/blank/stale image. Segmentation itself is only run when
//  `scene.needsSegmentation(isTriggered:)` says a behind-subject layer is
//  actually active for this frame's state — for Dark Vampire, that's
//  only while triggered (mouth open), so the resting state costs no
//  Vision call at all.
//

import CoreImage
import CoreVideo
import Observation
import UIKit
import Vision

@Observable
final class CinematicSceneEngine {
    private(set) var compositedImage: UIImage?
    /// Derived fresh from each frame's own tracked faces (see `ingest`),
    /// never set externally — exposed so the view layer can key a short
    /// transition animation off it without re-deriving the same trigger
    /// logic itself.
    private(set) var isTriggered = false

    var scene: CinematicScene?

    @ObservationIgnored private let queue = DispatchQueue(label: "org.firmecoding.photobooth.cinematic-scene", qos: .userInitiated)
    @ObservationIgnored private let segmentation = PersonSegmentationProvider(quality: .fast)
    @ObservationIgnored private let ciContext = CIContext()
    @ObservationIgnored private let busyLock = NSLock()
    @ObservationIgnored private var isBusy = false

    /// Called from the camera's frame-delivery queue (never the main
    /// actor), already throttled upstream to ~10Hz (the same tap Portal
    /// Mode uses). Drops the frame immediately if a previous one is still
    /// being processed, or if no scene is set. The trigger (e.g.
    /// mouth-open) is evaluated fresh from `faces` every call — the same
    /// live signal every other reactive effect already uses, no separate
    /// state to keep in sync.
    func ingest(_ pixelBuffer: CVPixelBuffer, faces: [TrackedFaceState]) {
        guard let scene else { return }
        busyLock.lock()
        if isBusy {
            busyLock.unlock()
            return
        }
        isBusy = true
        busyLock.unlock()

        let triggered = faces.first.map { scene.trigger.isSatisfied(by: $0.faceState) } ?? false
        let needsSegmentation = scene.needsSegmentation(isTriggered: triggered)

        queue.async { [weak self] in
            guard let self else { return }
            defer {
                self.busyLock.lock()
                self.isBusy = false
                self.busyLock.unlock()
            }

            let realCI = CIImage(cvPixelBuffer: pixelBuffer)
            guard let realCG = self.ciContext.createCGImage(realCI, from: realCI.extent) else { return }

            let mask: CIImage? = needsSegmentation
                ? self.segmentation.mask(pixelBuffer: pixelBuffer, orientation: .up).map { CIImage(cvPixelBuffer: $0) }
                : nil

            let outputCG = CinematicSceneCompositor.compositeFrame(
                realFrame: realCG, mask: mask, scene: scene, isTriggered: triggered, faces: faces, context: self.ciContext
            )

            let image = UIImage(cgImage: outputCG)
            Task { @MainActor in
                self.compositedImage = image
                self.isTriggered = triggered
            }
        }
    }

    /// Clears published state when this scene stops being active (effect
    /// switched away, or the camera screen goes away) so a stale
    /// composited frame never lingers on screen.
    func reset() {
        compositedImage = nil
        isTriggered = false
    }
}
