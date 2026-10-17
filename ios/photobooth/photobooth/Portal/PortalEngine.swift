//
//  PortalEngine.swift
//  photobooth
//
//  Owns the live, throttled Portal Mode pipeline: fast person segmentation
//  plus PortalCompositor, run off the main actor, publishing the latest
//  composited frame back to SwiftUI. Bounded by design — at most one frame
//  is ever being processed at a time; frames arriving while busy are simply
//  dropped rather than queued, so this can never build an unbounded backlog
//  or block the camera pipeline that feeds it.
//

import CoreImage
import CoreVideo
import Observation
import UIKit

@Observable
final class PortalEngine {
    private(set) var compositedImage: UIImage?

    var scene: PortalScene = .classic

    @ObservationIgnored private let queue = DispatchQueue(label: "org.firmecoding.photobooth.portal", qos: .userInitiated)
    @ObservationIgnored private let segmentation = PersonSegmentationProvider(quality: .fast)
    @ObservationIgnored private let ciContext = CIContext()
    @ObservationIgnored private let busyLock = NSLock()
    @ObservationIgnored private var isBusy = false
    @ObservationIgnored private var backgroundCache: [String: CIImage] = [:]

    /// Called from the camera's frame-delivery queue (never the main actor),
    /// already throttled upstream to ~10Hz. Drops the frame immediately if a
    /// previous one is still being processed.
    func ingest(_ pixelBuffer: CVPixelBuffer) {
        busyLock.lock()
        if isBusy {
            busyLock.unlock()
            return
        }
        isBusy = true
        busyLock.unlock()

        let scene = scene
        queue.async { [weak self] in
            guard let self else { return }
            defer {
                self.busyLock.lock()
                self.isBusy = false
                self.busyLock.unlock()
            }

            guard scene != .classic,
                  let maskBuffer = self.segmentation.mask(pixelBuffer: pixelBuffer, orientation: .up) else { return }

            let person = CIImage(cvPixelBuffer: pixelBuffer)
            let mask = CIImage(cvPixelBuffer: maskBuffer)
            let background = self.cachedBackground(for: scene, pixelSize: person.extent.size)

            guard let outputCG = PortalCompositor.composite(
                person: person,
                mask: mask,
                background: background,
                edgeTint: scene.edgeTintColor,
                context: self.ciContext
            ) else { return }

            let image = UIImage(cgImage: outputCG)
            Task { @MainActor in
                self.compositedImage = image
            }
        }
    }

    /// Clears published state when Portal Mode stops (scene reset to
    /// classic, or the camera screen goes away) so a stale composited frame
    /// never lingers on screen.
    func reset() {
        compositedImage = nil
    }

    // Only ever touched from `queue`, so no locking needed here.
    private func cachedBackground(for scene: PortalScene, pixelSize: CGSize) -> CIImage {
        let key = "\(scene.rawValue)-\(Int(pixelSize.width))x\(Int(pixelSize.height))"
        if let cached = backgroundCache[key] { return cached }
        let image = CIImage(image: scene.backgroundImage(pixelSize: pixelSize)) ?? CIImage.empty()
        backgroundCache[key] = image
        return image
    }
}
